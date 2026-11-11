// Launcher for the Windows build: a UIKit port of dm/ios/Sources/Launcher.swift and LauncherSettings.swift (SwiftUI), so the app builds with clang alone (no Swift toolchain).
// Its look follows the SwiftUI launcher (upstream c13ddcf, the single settings screen): the game card on the left third (icon, name, version, Play); on the right two thirds an
// inset-grouped list with one section per settings section (Game, Controls, Performance) in table order, each row with its note under its label, choices as a menu button,
// ranges as a slider with a percentage, toggles as switches; then "Reset to tested defaults" and the memory available. Same contract: dm_show_launcher(view controller, done)
// shows the screen over the root view controller, puts every setting into the environment when Play is pressed and then calls done; it returns false (done is not called)
// when there is no launcher (no dm/launcher.json, DM_LAUNCHER=0, or a file it cannot read). Settings come from the app's dm/launcher.json (dm/games/settings.py): kind "choice"
// (options [[value, label]]), "range" (min / max / step, shown as a percentage) or "toggle" (on / off: the two values the variable takes, "1" / "0" when absent).
// A variable an env file set (DM_ENV_FILE_KEYS, main.m) is shown but kept. A row marked "disabled" (settings.tsv always/<condition>: listed for every game, but this one has
// nothing it acts on) is shown greyed out and never applied. Only a choice that differs from the game's default is kept, in NSUserDefaults under "launcher.<ENV>", as the Swift launcher does.
// Since the sync to upstream ccd834e0 it also follows Launcher.swift's Cloud saves section and its save check before Play (SaveSyncReport.swift), a row's "needs" (a sub-setting
// drawn only while the row it names has that value), DM_ENV_LAUNCH_KEYS / DM_SAVED_CHOICES=0 / DM_LAUNCHER=0's saved choices, a program's own dm/p<N> (DM_APP_DM), and GameMenu.swift's
// in-game menu (dm_game_menu below), which shows and saves the same choices.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "CloudSaves.h"
#import "DmGameMenu.h"
#include "save_sync.h"
#include <math.h>
#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface DmSetting : NSObject
@property (copy) NSString *env, *kind, *label, *note, *def, *section, *on, *off, *needs;
@property (copy) NSArray<NSArray<NSString *> *> *options;   // choice: [value, label]
@property double min, max, step; @property BOOL hasMin, hasMax, hasStep;
@property BOOL disabled;
@end
@implementation DmSetting
- (NSString *)sectionTitle { return self.section.length ? self.section : @"Game"; }
- (NSString *)onValue { return self.on ?: @"1"; }
- (NSString *)offValue { return self.off ?: @"0"; }
- (BOOL)isDefault:(NSString *)v {   // a range compares as numbers (a slider writes 1.00 for 1.0)
    if ([self.kind isEqualToString:@"range"]) return fabs(v.doubleValue - self.def.doubleValue) < 1e-6;
    return [v isEqualToString:self.def];
}
- (BOOL)accepts:(NSString *)v {   // a saved choice the game still offers
    if ([self.kind isEqualToString:@"choice"]) return [self.options indexOfObjectPassingTest:^BOOL(NSArray *o, NSUInteger i, BOOL *stop) { return [o[0] isEqualToString:v]; }] != NSNotFound;
    if ([self.kind isEqualToString:@"range"]) {
        NSScanner *sc = [NSScanner scannerWithString:v]; double d;
        return [sc scanDouble:&d] && sc.isAtEnd && isfinite(d) && self.hasMin && self.hasMax && d >= self.min && d <= self.max;
    }
    if ([self.kind isEqualToString:@"toggle"]) return [v isEqualToString:self.onValue] || [v isEqualToString:self.offValue];
    return YES;
}
@end

static NSString *str(NSDictionary *d, NSString *k) { id v = d[k]; return [v isKindOfClass:NSString.class] ? v : nil; }

static NSArray<DmSetting *> *load_settings(NSData *data) {   // nil when the file does not decode (every row needs env, kind, label, note and default, as Launcher.swift's Decodable)
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"settings"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in root[@"settings"]) {
        if (![d isKindOfClass:NSDictionary.class]) return nil;
        DmSetting *s = [DmSetting new];
        s.env = str(d, @"env"); s.kind = str(d, @"kind"); s.label = str(d, @"label"); s.note = str(d, @"note"); s.def = str(d, @"default");
        s.section = str(d, @"section"); s.on = str(d, @"on"); s.off = str(d, @"off"); s.needs = str(d, @"needs");
        if (!s.env || !s.kind || !s.label || !s.note || !s.def) return nil;
        if ([d[@"options"] isKindOfClass:NSArray.class]) {
            NSMutableArray *opts = [NSMutableArray array];
            for (id o in d[@"options"]) {
                if (![o isKindOfClass:NSArray.class] || [o count] < 2 || ![o[0] isKindOfClass:NSString.class] || ![o[1] isKindOfClass:NSString.class]) return nil;
                [opts addObject:@[o[0], o[1]]];
            }
            s.options = opts;
        }
        if ([d[@"min"] isKindOfClass:NSNumber.class]) { s.min = [d[@"min"] doubleValue]; s.hasMin = YES; }
        if ([d[@"max"] isKindOfClass:NSNumber.class]) { s.max = [d[@"max"] doubleValue]; s.hasMax = YES; }
        if ([d[@"step"] isKindOfClass:NSNumber.class]) { s.step = [d[@"step"] doubleValue]; s.hasStep = YES; }
        s.disabled = [d[@"disabled"] isKindOfClass:NSNumber.class] && [d[@"disabled"] boolValue];
        [out addObject:s];
    }
    return out;
}

static int increased_memory_limit(void);

// ---- model (LauncherSettings.swift's LauncherModel) ----
@interface DmLauncherModel : NSObject
@property (strong) NSArray<DmSetting *> *settings;
@property (strong) NSArray<NSString *> *sections;
@property (strong) NSSet<NSString *> *fromFile;   // set by an env file or by the launch environment: shown, not changed (Swift's fixed)
@property (strong) NSSet<NSString *> *fromLaunch;   // of those, the ones the launch environment set (DM_ENV_LAUNCH_KEYS, main.m)
@property BOOL ignoreSaved;   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
@property (strong) NSMutableDictionary<NSString *, NSString *> *values;
@end
static NSSet<NSString *> *env_keys(NSString *var) {
    NSMutableSet *s = [NSMutableSet set];
    for (NSString *k in [(NSProcessInfo.processInfo.environment[var] ?: @"") componentsSeparatedByString:@" "]) if (k.length) [s addObject:k];
    return s;
}
@implementation DmLauncherModel
- (instancetype)initWith:(NSArray<DmSetting *> *)settings {
    if (!(self = [super init])) return nil;
    _settings = settings; _values = [NSMutableDictionary dictionary];
    NSMutableArray *secs = [NSMutableArray array];
    for (DmSetting *s in settings) if (![secs containsObject:s.sectionTitle]) [secs addObject:s.sectionTitle];
    _sections = secs;
    _fromLaunch = env_keys(@"DM_ENV_LAUNCH_KEYS");
    NSSet *ff = [_fromLaunch setByAddingObjectsFromSet:env_keys(@"DM_ENV_FILE_KEYS")];
    _fromFile = ff;
    _ignoreSaved = [NSProcessInfo.processInfo.environment[@"DM_SAVED_CHOICES"] isEqualToString:@"0"];
    if (_ignoreSaved) fprintf(stderr, "launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n");
    // A device with 6 GB of memory or less (an A16 iPad, an iPhone 15): the defaults that hold the least memory, Handheld (most games render 720p instead of 1080p) and,
    // where the game has a render-scale hook, 75 % of its 3D size. Only the defaults change: a choice the player made stays, and Reset brings back these
    if (NSProcessInfo.processInfo.physicalMemory <= 6.5 * 1024 * 1024 * 1024) {
        for (DmSetting *s in settings) {
            if (s.disabled) continue;
            NSString *was = s.def;
            if ([s.env isEqualToString:@"DM_OPMODE"] && [s.def isEqualToString:@"1"]) s.def = @"0";
            else if ([s.env isEqualToString:@"DM_RENDER_SCALE"] && s.def.doubleValue > 0.75) s.def = @"0.75";
            else if ([s.env isEqualToString:@"DM_NVN_TEX_DISCARD"] && ![s.def isEqualToString:@"1"] && !increased_memory_limit()) s.def = @"1";   // the textures' second copy ran TotK out of memory; with Increased Memory Limit, Automatic is enough
            // A 60 fps patch (Tears of the Kingdom: GPU p95 24-28 ms on an A16 iPad) swings between 40 and 60 there: the game's own 30 holds steady
            // Metal 4 pipelines keep an archive and prebuild every shader pair before the first frame ("Preparing pipelines": 20,017 pairs and about 850 MB more for TotK), past a 6 GB device's limit
            else if (([s.env isEqualToString:@"DM_PSO_MTL4"] || [s.env isEqualToString:@"DM_PSO_PREBUILD"]) && ![s.def isEqualToString:@"0"]) s.def = @"0";
            else if ([s.env isEqualToString:@"DM_FPS_TARGET"] && [s.def isEqualToString:@"60"] && [s.options indexOfObjectPassingTest:^BOOL(NSArray *o, NSUInteger i, BOOL *stop) { return [o[0] isEqualToString:@"30"]; }] != NSNotFound) s.def = @"30";
            if (![was isEqualToString:s.def]) {
                s.note = [s.note.length ? [s.note stringByAppendingString:@" "] : @"" stringByAppendingString:@"Lowered for this device's memory."];
                fprintf(stderr, "launcher: %s default %s → %s (%.1f GB device)\n", s.env.UTF8String, was.UTF8String, s.def.UTF8String, NSProcessInfo.processInfo.physicalMemory / 1073741824.0);
            }
        }
    }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    // Once on a 6 GB device: a Metal 4 / prebuild choice saved by an earlier build goes back to the light default (it closed TotK for memory); the player can turn it on again
    if (NSProcessInfo.processInfo.physicalMemory <= 6.5 * 1024 * 1024 * 1024 && ![ud boolForKey:@"launcher.nxw_lowmem_v1"]) {
        for (NSString *k in @[@"DM_PSO_MTL4", @"DM_PSO_PREBUILD"]) [ud removeObjectForKey:[@"launcher." stringByAppendingString:k]];
        [ud setBool:YES forKey:@"launcher.nxw_lowmem_v1"];
    }
    for (DmSetting *s in settings) {
        NSString *envv = NSProcessInfo.processInfo.environment[s.env];
        if ([ff containsObject:s.env] && envv) { _values[s.env] = envv; continue; }
        id saved = _ignoreSaved ? nil : [ud objectForKey:[@"launcher." stringByAppendingString:s.env]];   // a string, as launcher.c reads it: not stringForKey:, which turns a number into one
        _values[s.env] = ([saved isKindOfClass:NSString.class] && [s accepts:saved]) ? saved : s.def;   // a saved choice the game no longer offers: its default
    }
    return self;
}
// A row with "needs" ("<VAR>=<value>") is a sub-setting of the row it names: drawn only while that setting has that value; a row naming a setting this game does not have stays drawn
- (BOOL)visible:(DmSetting *)s {
    NSRange eq = s.needs ? [s.needs rangeOfString:@"="] : NSMakeRange(NSNotFound, 0);
    if (eq.location == NSNotFound) return YES;
    NSString *v = self.values[[s.needs substringToIndex:eq.location]];
    return !v || [v isEqualToString:[s.needs substringFromIndex:eq.location + 1]];
}
- (NSArray<DmSetting *> *)inSection:(NSString *)sec {
    return [self.settings filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DmSetting *s, NSDictionary *b) { return [s.sectionTitle isEqualToString:sec] && [self visible:s]; }]];
}
- (NSString *)value:(DmSetting *)s { return self.values[s.env] ?: s.def; }
- (BOOL)locked:(DmSetting *)s { return s.disabled || [self.fromFile containsObject:s.env]; }
- (NSString *)note:(DmSetting *)s {
    if (s.disabled || ![self.fromFile containsObject:s.env]) return s.note;
    return [NSString stringWithFormat:@"%@Set by %@", s.note.length ? [s.note stringByAppendingString:@" · "] : @"", [self.fromLaunch containsObject:s.env] ? @"the launch environment" : @"an env file"];
}
- (double)rangeValue:(DmSetting *)s {
    NSString *v = [self value:s]; NSScanner *sc = [NSScanner scannerWithString:v]; double d;
    return ([sc scanDouble:&d] && sc.isAtEnd) ? d : (s.hasMax ? s.max : 1);
}
- (NSString *)percentage:(DmSetting *)s { return [NSString stringWithFormat:@"%ld %%", lround([self rangeValue:s] * 100)]; }
- (NSString *)choiceLabel:(DmSetting *)s {
    NSString *cur = [self value:s];
    for (NSArray *o in s.options) if ([o[0] isEqualToString:cur]) return o[1];
    return cur;
}
- (BOOL)changed {
    for (DmSetting *s in self.settings) if (!s.disabled && ![self.fromFile containsObject:s.env] && ![s isDefault:[self value:s]]) return YES;
    return NO;
}
// Every launcher choice back to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies the defaults
// (apply keeps no default), so leaving after Reset keeps them
- (void)reset {
    for (DmSetting *s in self.settings) if (![self.fromFile containsObject:s.env]) self.values[s.env] = s.def;
    fprintf(stderr, "launcher: settings reset to the game's defaults\n");
}
- (void)store:(DmSetting *)s value:(NSString *)v {   // only a choice that differs from the game's default is kept; nothing with DM_SAVED_CHOICES=0
    if (self.ignoreSaved) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults; NSString *key = [@"launcher." stringByAppendingString:s.env];
    if ([s isDefault:v]) [ud removeObjectForKey:key]; else [ud setObject:v forKey:key];
}
// Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
// differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
- (void)apply {
    for (DmSetting *s in self.settings) {
        NSString *v = [self value:s];
        if (s.disabled) continue;   // nothing in this game reads it
        if ([self.fromFile containsObject:s.env]) { fprintf(stderr, "launcher: %s kept at %s (%s)\n", s.env.UTF8String, v.UTF8String, [self.fromLaunch containsObject:s.env] ? "launch environment" : "env file"); continue; }
        [self store:s value:v];
        setenv(s.env.UTF8String, v.UTF8String, 1); fprintf(stderr, "launcher: %s=%s%s\n", s.env.UTF8String, v.UTF8String, [s isDefault:v] ? "" : " (changed)");
    }
}
// A choice made while the game runs (the in-game menu, dm_game_menu): saved as Play saves it, so the settings screen shows it at the next start, and put in the environment
- (void)choose:(DmSetting *)s value:(NSString *)v {
    if ([self.fromFile containsObject:s.env] || s.disabled || ![s accepts:v]) return;
    self.values[s.env] = v; [self store:s value:v]; setenv(s.env.UTF8String, v.UTF8String, 1);
    fprintf(stderr, "launcher: %s=%s (in-game menu)\n", s.env.UTF8String, v.UTF8String);
}
// DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
- (void)applySaved {
    for (DmSetting *s in self.settings) {
        if (s.disabled || [self.fromFile containsObject:s.env]) continue;
        NSString *v = [self value:s];
        if (![s isDefault:v]) { setenv(s.env.UTF8String, v.UTF8String, 1); fprintf(stderr, "launcher: %s=%s (saved choice)\n", s.env.UTF8String, v.UTF8String); }
    }
}
@end

// ---- cloud saves before Play (SaveSyncReport.swift): the host's comparison of this device's save with the cloud's, and what the launcher does with it ----
static const int kSaveSyncWaitMs = 60000;   // how long the cloud's file may take to come (an iCloud download) before the launcher says it did not
@interface DmSaveSyncReport : NSObject
@property BOOL sync, conflict; @property int cloud;   // cloud: 1 read, 0 no save there, -1 not read in time
@property (copy) NSString *localHash, *cloudHash, *cloudDevice;
@property (strong) NSDate *localSaved, *cloudSaved; @property long long localSize, cloudSize;
@end
@implementation DmSaveSyncReport
+ (instancetype)fromLine:(NSString *)line {   // nil when the line is not a report
    NSMutableDictionary *f = [NSMutableDictionary dictionary];
    for (NSString *pair in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        NSRange eq = [pair rangeOfString:@"="]; if (eq.location == NSNotFound) continue;
        f[[pair substringToIndex:eq.location]] = [pair substringFromIndex:eq.location + 1];
    }
    if (!f[@"sync"] || !f[@"conflict"] || !f[@"cloud"]) return nil;
    NSString *(^text)(NSString *) = ^NSString *(NSString *k) { return [f[k] isEqualToString:@"-"] ? @"" : (f[k] ?: @""); };
    DmSaveSyncReport *r = [DmSaveSyncReport new];
    r.sync = [f[@"sync"] isEqualToString:@"1"]; r.conflict = [f[@"conflict"] isEqualToString:@"1"]; r.cloud = [f[@"cloud"] intValue];
    r.localHash = text(@"local"); r.cloudHash = text(@"chash"); r.cloudDevice = text(@"cdevice");
    r.localSaved = [NSDate dateWithTimeIntervalSince1970:[f[@"saved"] doubleValue]]; r.cloudSaved = [NSDate dateWithTimeIntervalSince1970:[f[@"csaved"] doubleValue]];
    r.localSize = [f[@"size"] longLongValue]; r.cloudSize = [f[@"csize"] longLongValue];
    return r;
}
static NSString *when(NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new]; f.doesRelativeDateFormatting = YES; f.dateStyle = NSDateFormatterShortStyle; f.timeStyle = NSDateFormatterShortStyle;
    return [f stringFromDate:d];
}
static NSString *bytes(long long n) { return [NSByteCountFormatter stringFromByteCount:n countStyle:NSByteCountFormatterCountStyleFile]; }
- (NSString *)cloudDeviceKind {   // the device the cloud's save came from, by its model ("iPhone17,1", "Mac16,1")
    if ([self.cloudDevice hasPrefix:@"iPhone"]) return @"iPhone";
    if ([self.cloudDevice hasPrefix:@"iPad"]) return @"iPad";
    if ([self.cloudDevice containsString:@"Mac"]) return @"Mac";
    return self.cloudDevice.length ? self.cloudDevice : @"another device";
}
- (NSString *)localLabel { return [NSString stringWithFormat:@"This iPhone's: %@, %@", when(self.localSaved), bytes(self.localSize)]; }
- (NSString *)cloudLabel { return [NSString stringWithFormat:@"The %@'s in iCloud: %@, %@", self.cloudDeviceKind, when(self.cloudSaved), bytes(self.cloudSize)]; }
@end
// Blocks while the cloud's file downloads (kSaveSyncWaitMs at most). nil: no report (the host then decides as it always did)
static DmSaveSyncReport *save_sync_compare(void) {
    const char *save = getenv("DM_SAVE");   // getenv: main.m sets DM_SAVE and applies env.txt after NSProcessInfo's snapshot
    if (!save) { fprintf(stderr, "launcher: save sync: no DM_SAVE\n"); return nil; }
    char buf[1024] = {0};
    if (save_sync_report(save, dm_save_title(), NULL, kSaveSyncWaitMs, buf, sizeof buf) != 0) { fprintf(stderr, "launcher: save sync: no report on %s\n", save); return nil; }
    fprintf(stderr, "launcher: save sync: %s\n", buf);
    return [DmSaveSyncReport fromLine:@(buf)];
}

static DmLauncherModel *g_menu_model;   // the settings screen's model, which the in-game menu shows and saves (dm_game_menu); nil in an app without one

static UILabel *body_label(NSString *text) {
    UILabel *l = [UILabel new]; l.text = text; l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; l.textColor = UIColor.labelColor; l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

static UILabel *value_label(NSString *text) {
    UILabel *l = [UILabel new]; l.text = text; l.textColor = UIColor.secondaryLabelColor; l.textAlignment = NSTextAlignmentRight;
    l.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightRegular];
    l.translatesAutoresizingMaskIntoConstraints = NO; [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

// The label column of a row: the setting's name, and its note in footnote style under it (SwiftUI's settingLabel)
static UIStackView *label_stack(NSString *title, NSString *note, BOOL locked) {
    UIStackView *st = [UIStackView new]; st.axis = UILayoutConstraintAxisVertical; st.spacing = 4; st.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *l = body_label(title); if (locked) l.textColor = UIColor.tertiaryLabelColor; [st addArrangedSubview:l];
    if (note.length) {
        UILabel *n = body_label(note); n.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; n.textColor = UIColor.secondaryLabelColor; [st addArrangedSubview:n];
    }
    return st;
}

// Increased Memory Limit: whether the signature the app was installed with carries com.apple.developer.kernel.increased-memory-limit (true). Read from the entitlements blob in the
// executable's own code signature, which is what iOS goes by: a signing tool for a free Apple ID (SideStore, AltStore) drops the entitlement, a paid developer account keeps it
static int increased_memory_limit(void) {
    static int v = -1;
    if (v >= 0) return v;
    NSData *d = [NSData dataWithContentsOfFile:NSBundle.mainBundle.executablePath options:NSDataReadingMappedIfSafe error:nil];
    NSData *key = [@"com.apple.developer.kernel.increased-memory-limit</key>" dataUsingEncoding:NSUTF8StringEncoding];
    v = 0;
    if (d.length) {
        NSRange r = [d rangeOfData:key options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];   // the signature is at the end of the file
        if (r.location != NSNotFound) {
            NSUInteger at = NSMaxRange(r), n = MIN((NSUInteger)64, d.length - at);
            NSString *after = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(at, n)] encoding:NSASCIIStringEncoding];
            v = [[after stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"<true/>"];
        }
    }
    fprintf(stderr, "launcher: Increased Memory Limit %s (the app's signature)\n", v ? "on" : "off");
    return v;
}

// ---- the settings list ----
@interface DmSettingsVC : UITableViewController <UIDocumentPickerDelegate>
@property (strong) DmLauncherModel *m; @property (strong) NSTimer *timer; @property (strong) UILabel *memory;
@property (copy) NSString *cloudFolder, *cloudNote;   // Cloud saves (Launcher.swift's CloudSavesSection): the picked iCloud Drive folder ("" when off), and the line under it
@end
@implementation DmSettingsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 56;
    self.cloudNote = @""; [self refreshCloud];
    __weak DmSettingsVC *w = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { w.memory.text = [NSByteCountFormatter stringFromByteCount:(long long)os_proc_available_memory() countStyle:NSByteCountFormatterCountStyleMemory]; }];
}
- (void)dealloc { [self.timer invalidate]; }
- (NSInteger)resetSection { return self.m.sections.count; }
- (NSInteger)cloudSection { return self.m.sections.count + 1; }
- (NSInteger)memorySection { return self.m.sections.count + 2; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.m.sections.count + 3; }   // the sections, Reset, Cloud saves, Memory available
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    if (sec < (NSInteger)self.m.sections.count) return (NSInteger)[self.m inSection:self.m.sections[sec]].count;
    if (sec == self.cloudSection) return self.cloudFolder.length ? 3 : 2;   // the folder, Choose, and Turn off while there is one
    return sec == self.memorySection ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec {   // a section whose rows are all hidden sub-settings has no heading either
    return sec < (NSInteger)self.m.sections.count && [self.m inSection:self.m.sections[sec]].count ? self.m.sections[sec] : nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)sec {
    if (sec == self.resetSection) return @"Brings back all settings this game was tested with.";
    if (sec == self.cloudSection) return self.cloudNote.length ? self.cloudNote
        : @"Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups.";
    if (sec == self.memorySection && !increased_memory_limit())
        return @"Increased Memory Limit is off: iOS gives this app less memory, and a big game can be closed when an area loads. A free Apple ID cannot turn it on (the signing app drops it); a paid developer account can. Texture memory saver (Performance) helps meanwhile.";
    return nil;
}
- (void)refreshCloud {
    BOOL stale = NO; self.cloudFolder = dm_cloud_saves_path(&stale) ?: @"";
    if (stale && !self.cloudFolder.length) self.cloudNote = @"The folder you chose before is no longer readable (the app was signed differently). Please choose it again.";
}
- (void)pickCloudFolder {   // .open, not .import: the folder stays where it is and the bookmark keeps pointing at it
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    p.allowsMultipleSelection = NO; p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.firstObject) return;
    if (dm_store_cloud_saves(urls.firstObject)) { self.cloudNote = @"Saved. The game uses this folder when you press Play."; [self refreshCloud]; }
    else self.cloudNote = @"That folder could not be remembered — try a different one.";
    [self.tableView reloadData];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *v = c.contentView; UILayoutGuide *g = v.layoutMarginsGuide;
    if (ip.section == self.cloudSection) {
        if (ip.row == 0) {   // Cloud saves: the folder's name, or Off
            UILabel *l = body_label(@"Cloud saves"), *st = value_label(self.cloudFolder.length ? self.cloudFolder.lastPathComponent : @"Off");
            st.lineBreakMode = NSLineBreakByTruncatingMiddle; [st setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
            [v addSubview:l]; [v addSubview:st];
            [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
                [st.leadingAnchor constraintGreaterThanOrEqualToAnchor:l.trailingAnchor constant:12], [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
                [st.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
            return c;
        }
        BOOL off = ip.row == 2;
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration]; cfg.contentInsets = NSDirectionalEdgeInsetsZero;
        cfg.title = off ? @"Turn off cloud saves" : self.cloudFolder.length ? @"Choose a different folder…" : @"Choose a folder in iCloud Drive…";
        if (off) cfg.baseForegroundColor = UIColor.systemRedColor;
        __weak DmSettingsVC *w = self;
        UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
            if (!off) { [w pickCloudFolder]; return; }
            dm_clear_cloud_saves(); w.cloudNote = @""; [w refreshCloud]; [w.tableView reloadData];
        }]];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading; b.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:b];
        [NSLayoutConstraint activateConstraints:@[[b.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [b.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [b.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    if (ip.section == self.resetSection) {   // Reset to tested defaults: a button row, enabled while a choice differs from the defaults
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration]; cfg.title = @"Reset to tested defaults"; cfg.contentInsets = NSDirectionalEdgeInsetsZero;
        __weak DmSettingsVC *w = self;
        UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [w.m reset]; [w.tableView reloadData]; }]];
        b.enabled = self.m.changed; b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading; b.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:b];
        [NSLayoutConstraint activateConstraints:@[[b.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [b.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [b.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    if (ip.section == self.memorySection && ip.row == 1) {   // Increased Memory Limit: On (green) / Off (orange)
        UILabel *l = body_label(@"Increased Memory Limit");
        int on = increased_memory_limit();
        UILabel *st = value_label(on ? @"● On" : @"● Off"); st.textColor = on ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        [v addSubview:l]; [v addSubview:st];
        [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [st.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    if (ip.section == self.memorySection) {   // Memory available
        UILabel *l = body_label(@"Memory available");
        self.memory = value_label([NSByteCountFormatter stringFromByteCount:(long long)os_proc_available_memory() countStyle:NSByteCountFormatterCountStyleMemory]);
        [v addSubview:l]; [v addSubview:self.memory];
        [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [self.memory.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [self.memory.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
            [v.heightAnchor constraintGreaterThanOrEqualToConstant:48]]];
        return c;
    }
    DmSetting *s = [self.m inSection:self.m.sections[ip.section]][ip.row]; BOOL locked = [self.m locked:s];
    NSInteger tag = [self.m.settings indexOfObject:s];
    UIStackView *lab = label_stack(s.label, [self.m note:s], locked);
    NSMutableArray *cs = [NSMutableArray array];
    if ([s.kind isEqualToString:@"range"]) {   // label and percentage on one line, the slider under them (SwiftUI's VStack)
        UILabel *pct = value_label([self.m percentage:s]); pct.tag = 1000 + tag;
        UISlider *sl = [UISlider new]; sl.translatesAutoresizingMaskIntoConstraints = NO;
        sl.minimumValue = s.hasMin ? s.min : 0; sl.maximumValue = s.hasMax ? s.max : 1; sl.value = [self.m rangeValue:s];
        sl.enabled = !locked; sl.accessibilityLabel = s.label; sl.accessibilityValue = pct.text; sl.tag = tag;
        [sl addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
        [sl addTarget:self action:@selector(slidEnd:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [v addSubview:lab]; [v addSubview:pct]; [v addSubview:sl];
        [cs addObjectsFromArray:@[[lab.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [lab.topAnchor constraintEqualToAnchor:g.topAnchor],
            [pct.leadingAnchor constraintGreaterThanOrEqualToAnchor:lab.trailingAnchor constant:12], [pct.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [pct.firstBaselineAnchor constraintEqualToAnchor:lab.firstBaselineAnchor],
            [sl.topAnchor constraintEqualToAnchor:lab.bottomAnchor constant:8], [sl.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [sl.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [sl.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
    } else {
        UIView *ctl;
        if ([s.kind isEqualToString:@"choice"]) {   // SwiftUI's .menu Picker: the value with up / down chevrons, opening a menu
            UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
            cfg.title = [self.m choiceLabel:s]; cfg.baseForegroundColor = UIColor.secondaryLabelColor;
            cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
            cfg.imagePlacement = NSDirectionalRectEdgeTrailing; cfg.imagePadding = 5; cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 0);
            cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) { NSMutableDictionary *m = [a mutableCopy]; m[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; return m; };
            UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
            b.showsMenuAsPrimaryAction = YES; b.changesSelectionAsPrimaryAction = NO; b.enabled = !locked;
            b.menu = [self menuFor:s button:b];
            ctl = b;
        } else {
            UISwitch *sw = [UISwitch new]; sw.on = [[self.m value:s] isEqualToString:s.onValue]; sw.enabled = !locked; sw.tag = tag;
            [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            ctl = sw;
        }
        ctl.translatesAutoresizingMaskIntoConstraints = NO;
        [ctl setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [v addSubview:lab]; [v addSubview:ctl];
        [cs addObjectsFromArray:@[[lab.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [lab.topAnchor constraintEqualToAnchor:g.topAnchor], [lab.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
            [ctl.leadingAnchor constraintGreaterThanOrEqualToAnchor:lab.trailingAnchor constant:12], [ctl.trailingAnchor constraintEqualToAnchor:g.trailingAnchor], [ctl.centerYAnchor constraintEqualToAnchor:v.centerYAnchor]]];
    }
    [cs addObject:[v.heightAnchor constraintGreaterThanOrEqualToConstant:48]];
    [NSLayoutConstraint activateConstraints:cs];
    return c;
}

- (UIMenu *)menuFor:(DmSetting *)s button:(UIButton *)b {
    NSMutableArray *items = [NSMutableArray array];
    NSString *cur = [self.m value:s];
    __weak DmSettingsVC *w = self; __weak UIButton *wb = b;
    for (NSArray *o in s.options) {
        UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil handler:^(UIAction *act) {
            DmSettingsVC *me = w; if (!me) return;
            me.m.values[s.env] = o[0];
            UIButtonConfiguration *cfg = wb.configuration; cfg.title = o[1]; wb.configuration = cfg;
            wb.menu = [me menuFor:s button:wb];
            [me changed:s];
        }];
        a.state = [o[0] isEqualToString:cur] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:items];
}
- (void)refreshReset { [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:self.resetSection]] withRowAnimation:UITableViewRowAnimationNone]; }
- (void)changed:(DmSetting *)s {   // a row other rows need ("needs"): the list is drawn again, so its sub-settings show or hide
    for (DmSetting *o in self.m.settings) if ([o.needs hasPrefix:[s.env stringByAppendingString:@"="]]) { [self.tableView reloadData]; return; }
    [self refreshReset];
}

- (void)slid:(UISlider *)sl {
    DmSetting *s = self.m.settings[sl.tag];
    double step = s.hasStep ? s.step : 0.05, lo = s.hasMin ? s.min : 0;
    double v = step > 0 ? lo + round((sl.value - lo) / step) * step : sl.value;   // SwiftUI's Slider(step:) snaps the same way
    self.m.values[s.env] = [NSString stringWithFormat:@"%.2f", v];
    UILabel *pct = [sl.superview viewWithTag:1000 + sl.tag];
    pct.text = [self.m percentage:s]; sl.accessibilityValue = pct.text;
}
- (void)slidEnd:(UISlider *)sl { [self refreshReset]; }
- (void)toggled:(UISwitch *)sw { DmSetting *s = self.m.settings[sw.tag]; self.m.values[s.env] = sw.on ? s.onValue : s.offValue; [self changed:s]; }
@end

// ---- the screen: game card on the left third, settings on the right two thirds ----
@interface DmLauncherVC : UIViewController
@property (strong) DmLauncherModel *m; @property (copy) void (^play)(void);
@property (strong) UIButton *playButton; @property (strong) UIStackView *checkingView;
@property BOOL checking; @property NSInteger check;   // which Play the running cloud check is for: one the player went on from without it is dropped
@end
@implementation DmLauncherVC
static id info(NSString *k) { return [NSBundle.mainBundle objectForInfoDictionaryKey:k]; }
static UIImage *app_icon(void) {
    UIImage *i = [UIImage imageNamed:@"AppIcon"]; if (i) return i;
    NSDictionary *icons = info(@"CFBundleIcons"); NSArray *files = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] : nil;
    for (NSString *f in [files reverseObjectEnumerator]) { UIImage *im = [f isKindOfClass:NSString.class] ? [UIImage imageNamed:f] : nil; if (im) return im; }
    return [UIImage imageNamed:@"AppIcon60x60"];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIStackView *card = [UIStackView new]; card.axis = UILayoutConstraintAxisVertical; card.alignment = UIStackViewAlignmentCenter; card.spacing = 16;
    UIImage *icon = app_icon();
    if (icon) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon]; iv.layer.cornerRadius = 22; iv.layer.cornerCurve = kCACornerCurveContinuous; iv.clipsToBounds = YES;
        iv.isAccessibilityElement = NO; [iv.widthAnchor constraintEqualToConstant:96].active = YES; [iv.heightAnchor constraintEqualToConstant:96].active = YES;
        [card addArrangedSubview:iv];
    }
    UILabel *name = [UILabel new]; name.text = [info(@"CFBundleDisplayName") isKindOfClass:NSString.class] ? info(@"CFBundleDisplayName") : @"Game";
    UIFontDescriptor *fd = [[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1].fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    name.font = [UIFont fontWithDescriptor:fd size:0]; name.numberOfLines = 0; name.textAlignment = NSTextAlignmentCenter; [card addArrangedSubview:name];
    UILabel *ver = [UILabel new]; ver.text = [NSString stringWithFormat:@"Version %@", info(@"CFBundleShortVersionString") ?: @""];
    ver.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout]; ver.textColor = UIColor.secondaryLabelColor; [card addArrangedSubview:ver];
    UIButtonConfiguration *cfg = nil;
    SEL glass = NSSelectorFromString(@"prominentGlassButtonConfiguration");   // iOS 26's .glassProminent, as Launcher.swift; the filled style before it
    if ([UIButtonConfiguration respondsToSelector:glass]) cfg = ((UIButtonConfiguration *(*)(id, SEL))[UIButtonConfiguration methodForSelector:glass])(UIButtonConfiguration.class, glass);
    if (!cfg) cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.buttonSize = UIButtonConfigurationSizeLarge; cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIFontDescriptor *pd = [[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3].fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    cfg.attributedTitle = [[NSAttributedString alloc] initWithString:@"Play" attributes:@{NSFontAttributeName: [UIFont fontWithDescriptor:pd size:0]}];
    __weak DmLauncherVC *w = self;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [w start]; }]];
    [b.widthAnchor constraintEqualToConstant:220].active = YES; [card addArrangedSubview:b]; self.playButton = b;
    // While the cloud's save is checked: a spinner, and Play Without It
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]; [spin startAnimating];
    UILabel *cl = [UILabel new]; cl.text = @"Checking the cloud save…"; cl.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout]; cl.textColor = UIColor.secondaryLabelColor;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[spin, cl]]; row.spacing = 6;
    UIButtonConfiguration *wc = [UIButtonConfiguration plainButtonConfiguration]; wc.title = @"Play Without It";
    UIButton *without = [UIButton buttonWithConfiguration:wc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { w.checking = NO; [w go:@"offline"]; }]];
    self.checkingView = [[UIStackView alloc] initWithArrangedSubviews:@[row, without]]; self.checkingView.axis = UILayoutConstraintAxisVertical;
    self.checkingView.alignment = UIStackViewAlignmentCenter; self.checkingView.spacing = 6; self.checkingView.hidden = YES; [card addArrangedSubview:self.checkingView];
    card.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:card];

    DmSettingsVC *list = [[DmSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped]; list.m = self.m;
    [self addChildViewController:list]; list.view.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:list.view]; [list didMoveToParentViewController:self];
    UIView *v = self.view; UILayoutGuide *safe = v.safeAreaLayoutGuide;
    UILayoutGuide *left = [UILayoutGuide new]; [v addLayoutGuide:left];   // the card in a third, the list in two thirds (Launcher.swift's GeometryReader split)
    [NSLayoutConstraint activateConstraints:@[
        [list.view.topAnchor constraintEqualToAnchor:v.topAnchor], [list.view.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
        [list.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor], [list.view.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:2.0 / 3.0],
        [left.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [left.trailingAnchor constraintEqualToAnchor:list.view.leadingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:left.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:left.widthAnchor constant:-32]]];
}
- (void)setChecking:(BOOL)on { _checking = on; self.playButton.enabled = !on; self.checkingView.hidden = !on; }
// Play, once the cloud's save is compared with this iPhone's (save_sync_report): a save that changed on both sides is the player's pick, not the newer file's,
// and a cloud save that did not come is said so before the game starts without it
- (void)start {
    NSInteger mine = ++self.check; self.checking = YES;
    dm_cloud_saves_env();   // DM_SAVE_SYNC from the picked folder, as the game's mount will read it (front_ios.m calls it again at the start)
    __weak DmLauncherVC *w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DmSaveSyncReport *r = save_sync_compare();
        dispatch_async(dispatch_get_main_queue(), ^{
            DmLauncherVC *me = w;
            if (!me || !me.checking || me.check != mine) return;   // the player played without it
            me.checking = NO;
            if (!r || !r.sync) [me go:nil];   // no report (no save folder, no title ID): nothing is set and the host decides as it always did
            else if (r.cloud < 0) [me ask:r unreadable:YES];
            else if (r.conflict) [me ask:r unreadable:NO];
            else [me go:@"ask"];   // nothing to choose now; if the cloud's changes before the mount, the mount replaces neither (save_sync.c read_choice)
        });
    });
}
- (void)ask:(DmSaveSyncReport *)r unreadable:(BOOL)unreadable {
    UIAlertController *a;
    __weak DmLauncherVC *w = self;
    if (unreadable) {
        a = [UIAlertController alertControllerWithTitle:@"The cloud save didn't come" message:[NSString stringWithFormat:@"iCloud didn't deliver this game's save in %d seconds. If you play this iPhone's save now, it is not sent to iCloud until it has been compared with the cloud's at a later start.", kSaveSyncWaitMs / 1000] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Play This iPhone's Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [w go:@"offline"]; }]];   // the mount does not wait for the cloud again
        [a addAction:[UIAlertAction actionWithTitle:@"Try Again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { dispatch_async(dispatch_get_main_queue(), ^{ [w start]; }); }]];
    } else {
        a = [UIAlertController alertControllerWithTitle:@"Which save do you want to play?" message:@"Both this iPhone's save and the one in iCloud changed since they were last the same. The newer one is not always the one with more progress: a new game saved a minute later is newer. The one you don't pick is kept in the save's backups folder." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:r.localLabel style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [w go:[@"local:" stringByAppendingString:r.localHash]]; }]];
        [a addAction:[UIAlertAction actionWithTitle:r.cloudLabel style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [w go:[@"cloud:" stringByAppendingString:r.cloudHash]]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)go:(NSString *)choice {   // the answer goes to the host as DM_SAVE_SYNC_CHOICE (docs/frontends.md, The cloud saves folder)
    if (choice) { setenv("DM_SAVE_SYNC_CHOICE", choice.UTF8String, 1); fprintf(stderr, "launcher: DM_SAVE_SYNC_CHOICE=%s\n", choice.UTF8String); }
    if (self.play) self.play();
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }   // the game's four-orientation policy (DmHostingController.swift)
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

// ---- the in-game menu (GameMenu.swift), opened by the gamepad's menu button at the top centre (DmGamepad.m): the controller layout, then the settings-screen settings the running
// game takes at once (front_ios.m dm_setting_live), grouped as on the settings screen without its headings, one row each. A pick is saved as Play saves it (choose:value:), so the
// settings screen shows it at the next start; a setting an env file fixes is shown, not changed. Settings that need the next start, and the sliders, stay on the settings screen ----
static UIMenuElement *game_menu_row(DmLauncherModel *m, DmSetting *s) {
    NSString *now = [m value:s]; BOOL fixed = [m.fromFile containsObject:s.env];
    UIMenuElementAttributes attrs = fixed ? UIMenuElementAttributesDisabled : 0;
    void (^pick)(NSString *) = ^(NSString *v) { [m choose:s value:v]; dm_setting_live(s.env.UTF8String, v.UTF8String); };
    if ([s.kind isEqualToString:@"toggle"]) {
        BOOL on = [now isEqualToString:s.onValue];
        UIAction *a = [UIAction actionWithTitle:s.label image:nil identifier:nil handler:^(UIAction *x) { pick(on ? s.offValue : s.onValue); }];
        a.attributes = attrs; a.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (fixed) a.subtitle = @"Set in env.txt";
        return a;
    }
    NSMutableArray *acts = [NSMutableArray array]; NSString *current = now;
    for (NSArray *o in s.options) {
        if ([o[0] isEqualToString:now]) current = o[1];
        UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil handler:^(UIAction *x) { pick(o[0]); }];
        a.attributes = attrs; a.state = [o[0] isEqualToString:now] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [acts addObject:a];
    }
    UIMenu *menu = [UIMenu menuWithTitle:s.label image:nil identifier:nil options:UIMenuOptionsSingleSelection children:acts];
    if (fixed) menu.subtitle = [NSString stringWithFormat:@"%@, set in env.txt", current];
    return menu;
}
static NSArray<UIMenuElement *> *game_menu_items(void) {
    NSArray *names = @[@"2D", @"3D", @"Tap"];
    NSMutableArray *layouts = [NSMutableArray array];
    for (int l = 0; l < 3; l++) {
        if (!dm_pad_layout_offered(l)) continue;
        UIAction *a = [UIAction actionWithTitle:names[l] image:nil identifier:nil handler:^(UIAction *x) { dm_pad_layout_set(l); }];
        a.state = dm_pad_layout() == l ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layouts addObject:a];
    }
    UIMenu *layout = [UIMenu menuWithTitle:@"Controller layout" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:layouts];   // a choice's value shows in its submenu
    NSMutableArray *items = [NSMutableArray array]; BOOL placed = NO;
    DmLauncherModel *m = g_menu_model;
    for (NSString *sec in m.sections) {
        NSMutableArray *rows = [NSMutableArray array];
        if ([sec isEqualToString:@"Controls"]) { [rows addObject:layout]; placed = YES; }
        for (DmSetting *s in [m inSection:sec])
            if (!s.disabled && ([s.kind isEqualToString:@"choice"] || [s.kind isEqualToString:@"toggle"]) && dm_setting_live(s.env.UTF8String, NULL)) [rows addObject:game_menu_row(m, s)];
        if (rows.count) [items addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:rows]];
    }
    if (!placed) [items insertObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[layout]] atIndex:0];
    return items;
}
void *dm_game_menu(void) {   // a retained UIMenu, built again each time it opens, so it shows the current choices
    UIDeferredMenuElement *d = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^done)(NSArray<UIMenuElement *> *)) { done(game_menu_items()); }];
    UIMenu *menu = [UIMenu menuWithTitle:g_menu_model ? @"More settings on the start screen" : @"" children:@[d]];
    return (void *)CFBridgingRetain(menu);
}

// A capture IPA (win/build_ipa_windows.py: the run-time shader capture done on the device instead of a Mac) sets DM_GLSLC_CAPTURE / DM_VK_CAPTURE / DM_GL_CAPTURE in its dm/env.txt
// to a folder relative to Documents (main.m makes Documents the working directory); the Vulkan and GL captures write into the folder without making it, so it is made here, before the game starts
static void make_capture_folders(void) {
    static const char *const keys[] = {"DM_GLSLC_CAPTURE", "DM_VK_CAPTURE", "DM_GL_CAPTURE"};
    for (int i = 0; i < 3; i++) {
        const char *k = keys[i], *d = getenv(k);
        if (d && *d) { [NSFileManager.defaultManager createDirectoryAtPath:@(d) withIntermediateDirectories:YES attributes:nil error:nil]; fprintf(stderr, "capture: %s → Documents/%s\n", k, d); }
    }
}

bool dm_show_launcher(void *view_controller, void (*done)(void)) {
    make_capture_folders();
    const char *appdm = getenv("DM_APP_DM");   // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    NSString *dir = appdm ? @(appdm) : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"launcher.json"]];
    if (!data) return false;
    NSArray<DmSetting *> *settings = load_settings(data);
    if (!settings.count) { fprintf(stderr, "[RED] launcher: dm/launcher.json cannot be read; starting the game\n"); return false; }
    DmLauncherModel *model = [[DmLauncherModel alloc] initWith:settings];
    g_menu_model = model;   // the in-game menu shows and saves the same choices
    const char *off = getenv("DM_LAUNCHER");
    if (off && !strcmp(off, "0")) { fprintf(stderr, "launcher: off (DM_LAUNCHER=0)\n"); [model applySaved]; return false; }
    UIViewController *parent = (__bridge UIViewController *)view_controller;
    DmLauncherVC *vc = [DmLauncherVC new]; vc.m = model; vc.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak DmLauncherVC *wvc = vc; __block BOOL started = NO;
    vc.play = ^{
        if (started || !wvc) return;
        started = YES;
        [model apply];
        [wvc dismissViewControllerAnimated:NO completion:^{ done(); }];
    };
    [parent presentViewController:vc animated:NO completion:nil];
    fprintf(stderr, "launcher: %lu settings shown\n", (unsigned long)settings.count);
    return true;
}
