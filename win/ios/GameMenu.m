// The in-game menu for the Windows build: dm/ios/Sources/GameMenu.swift's dm_game_menu (DmGameMenu.h) in Objective-C, so no Swift toolchain is needed. The gamepad's menu button at the
// top centre opens it (DmGamepad.m). It holds the controller layout (2D, 3D, Tap: the ones dm_pad_layout_offered allows), rebuilt each time it opens so it shows the current choice.
// GameMenu.swift also lists the launcher settings the running game takes at once, from Launcher.swift's model; win/ios/Launcher.m has no such model, so those stay on the settings screen
#import <UIKit/UIKit.h>
#include "../../dm/ios/Sources/DmGameMenu.h"

static NSArray<UIMenuElement *> *game_menu_items(void) {
    NSArray<NSString *> *names = @[@"2D", @"3D", @"Tap"];
    NSMutableArray<UIMenuElement *> *layouts = [NSMutableArray array];
    for (int l = 0; l < 3; l++) {
        if (!dm_pad_layout_offered(l)) continue;
        UIAction *a = [UIAction actionWithTitle:names[l] image:nil identifier:nil handler:^(__kindof UIAction *x) { (void)x; dm_pad_layout_set(l); }];
        a.state = dm_pad_layout() == l ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layouts addObject:a];
    }
    UIMenu *layout = [UIMenu menuWithTitle:@"Controller layout" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:layouts];
    return @[[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[layout]]];
}

void *dm_game_menu(void) {   // a retained UIMenu (DmGamepad.m takes it with CFBridgingRelease)
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^done)(NSArray<UIMenuElement *> *)) { done(game_menu_items()); }];
    UIMenu *menu = [UIMenu menuWithTitle:@"" children:@[items]];
    return (void *)CFBridgingRetain(menu);
}
