 /*
  Simple DirectMedia Layer
  Copyright (C) 1997-2018 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
#include "../../SDL_internal.h"

#if SDL_VIDEO_DRIVER_UIKIT

#include "SDL_uikitview.h"

#include "SDL_hints.h"
#include "SDL_keyboard.h"
#include "../../events/SDL_mouse_c.h"
#include "../../events/SDL_touch_c.h"
#include "../../events/SDL_events_c.h"

#import "SDL_uikitappdelegate.h"
#import "SDL_uikitmodes.h"
#import "SDL_uikitwindow.h"

@implementation SDL_uikitview {
    SDL_Window *sdlwindow;

    SDL_TouchID touchId;
    UITouch * __weak firstFingerDown;
    UITouch * __weak secondaryButtonDown;
    UIKeyModifierFlags activeModifiers;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
#if TARGET_OS_TV
        if (SDL_GetHintBoolean(SDL_HINT_APPLE_TV_REMOTE_SWIPES_AS_ARROW_KEYS, SDL_TRUE)) {
            /* Apple TV Remote touchpad swipe gestures. */
            UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeGesture:)];
            swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
            [self addGestureRecognizer:swipeUp];

            UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeGesture:)];
            swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
            [self addGestureRecognizer:swipeDown];

            UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeGesture:)];
            swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
            [self addGestureRecognizer:swipeLeft];

            UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeGesture:)];
            swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
            [self addGestureRecognizer:swipeRight];
        }
#endif

        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.autoresizesSubviews = YES;

#if !TARGET_OS_TV
        self.multipleTouchEnabled = YES;

        /* iPadOS 13.4+ reports trackpad/mouse movement that happens with no
           button held through a hover recogniser rather than through touches,
           so without this the app is never told the pointer moved and
           mouse-over states only update on click. */
        if (@available(iOS 13.4, *)) {
            UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc]
                initWithTarget:self action:@selector(pointerHover:)];
            /* This recogniser exists only to observe hover events; it must
               never swallow or postpone a real touch. The defaults would
               cancel touches in the view and hold back touchesEnded until the
               recogniser fails. */
            hover.cancelsTouchesInView = NO;
            hover.delaysTouchesBegan = NO;
            hover.delaysTouchesEnded = NO;
            [self addGestureRecognizer:hover];
        }
#endif

        touchId = 1;
        SDL_AddTouch(touchId, "");
    }

    return self;
}

- (void)setSDLWindow:(SDL_Window *)window
{
    SDL_WindowData *data = nil;

    if (window == sdlwindow) {
        return;
    }

    /* Remove ourself from the old window. */
    if (sdlwindow) {
        SDL_uikitview *view = nil;
        data = (__bridge SDL_WindowData *) sdlwindow->driverdata;

        [data.views removeObject:self];

        [self removeFromSuperview];

        /* Restore the next-oldest view in the old window. */
        view = data.views.lastObject;

        data.viewcontroller.view = view;

        data.uiwindow.rootViewController = nil;
        data.uiwindow.rootViewController = data.viewcontroller;

        [data.uiwindow layoutIfNeeded];
    }

    /* Add ourself to the new window. */
    if (window) {
        data = (__bridge SDL_WindowData *) window->driverdata;

        /* Make sure the SDL window has a strong reference to this view. */
        [data.views addObject:self];

        /* Replace the view controller's old view with this one. */
        [data.viewcontroller.view removeFromSuperview];
        data.viewcontroller.view = self;

        /* The root view controller handles rotation and the status bar.
         * Assigning it also adds the controller's view to the window. We
         * explicitly re-set it to make sure the view is properly attached to
         * the window. Just adding the sub-view if the root view controller is
         * already correct causes orientation issues on iOS 7 and below. */
        data.uiwindow.rootViewController = nil;
        data.uiwindow.rootViewController = data.viewcontroller;

        /* The view's bounds may not be correct until the next event cycle. That
         * might happen after the current dimensions are queried, so we force a
         * layout now to immediately update the bounds. */
        [data.uiwindow layoutIfNeeded];
    }

    sdlwindow = window;
}

- (CGPoint)touchLocation:(UITouch *)touch shouldNormalize:(BOOL)normalize
{
    CGPoint point = [touch locationInView:self];

    if (normalize) {
        CGRect bounds = self.bounds;
        point.x /= bounds.size.width;
        point.y /= bounds.size.height;
    }

    return point;
}

- (float)pressureForTouch:(UITouch *)touch
{
#ifdef __IPHONE_9_0
    if ([touch respondsToSelector:@selector(force)]) {
        return (float) touch.force;
    }
#endif

    return 1.0f;
}

#if !TARGET_OS_TV
- (void)pointerHover:(UIHoverGestureRecognizer *)recognizer API_AVAILABLE(ios(13.4))
{
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            CGPoint point = [recognizer locationInView:self];
            /* Mouse ID 0, not SDL_TOUCH_MOUSEID: this is a real pointer, and
               applications routinely discard touch-emulated mouse events. */
            SDL_SendMouseMotion(sdlwindow, 0, 0, (int)point.x, (int)point.y);
            break;
        }
        default:
            break;
    }
}

/* Is this touch a secondary (right) click from an indirect pointer? */
- (BOOL)isSecondaryClick:(UITouch *)touch withEvent:(UIEvent *)event
{
    if (@available(iOS 13.4, *)) {
        return touch.type == UITouchTypeIndirectPointer &&
               (event.buttonMask & UIEventButtonMaskSecondary) != 0;
    }
    return NO;
}
#endif

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        float pressure = [self pressureForTouch:touch];

#if !TARGET_OS_TV
        /* A secondary click has to be reported as a real right-button press:
           the touch path below can only ever express SDL_BUTTON_LEFT. */
        if (!secondaryButtonDown && [self isSecondaryClick:touch withEvent:event]) {
            CGPoint point = [self touchLocation:touch shouldNormalize:NO];
            SDL_SendMouseMotion(sdlwindow, 0, 0, (int)point.x, (int)point.y);
            SDL_SendMouseButton(sdlwindow, 0, SDL_PRESSED, SDL_BUTTON_RIGHT);
            secondaryButtonDown = touch;
            continue;
        }
#endif

        if (!firstFingerDown) {
            CGPoint locationInView = [self touchLocation:touch shouldNormalize:NO];
            int clicks = (int) touch.tapCount;

            /* send mouse moved event */
            SDL_SendMouseMotion(sdlwindow, SDL_TOUCH_MOUSEID, 0, locationInView.x, locationInView.y);

            /* send mouse down event */
            SDL_SendMouseButtonClicks(sdlwindow, SDL_TOUCH_MOUSEID, SDL_PRESSED, SDL_BUTTON_LEFT, clicks);

            firstFingerDown = touch;
        }

        CGPoint locationInView = [self touchLocation:touch shouldNormalize:YES];
        SDL_SendTouch(touchId, (SDL_FingerID)((size_t)touch),
                      SDL_TRUE, locationInView.x, locationInView.y, pressure);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        float pressure = [self pressureForTouch:touch];

#if !TARGET_OS_TV
        if (touch == secondaryButtonDown) {
            /* buttonMask is already clear by now, so go by the tracked touch. */
            SDL_SendMouseButton(sdlwindow, 0, SDL_RELEASED, SDL_BUTTON_RIGHT);
            secondaryButtonDown = nil;
            continue;
        }
#endif

        if (touch == firstFingerDown) {
            /* send mouse up */
            int clicks = (int) touch.tapCount;
            SDL_SendMouseButtonClicks(sdlwindow, SDL_TOUCH_MOUSEID, SDL_RELEASED, SDL_BUTTON_LEFT, clicks);
            firstFingerDown = nil;
        }

        CGPoint locationInView = [self touchLocation:touch shouldNormalize:YES];
        SDL_SendTouch(touchId, (SDL_FingerID)((size_t)touch),
                      SDL_FALSE, locationInView.x, locationInView.y, pressure);
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesEnded:touches withEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        float pressure = [self pressureForTouch:touch];

#if !TARGET_OS_TV
        if (touch == secondaryButtonDown) {
            CGPoint point = [self touchLocation:touch shouldNormalize:NO];
            SDL_SendMouseMotion(sdlwindow, 0, 0, (int)point.x, (int)point.y);
            continue;
        }
#endif

        if (touch == firstFingerDown) {
            CGPoint locationInView = [self touchLocation:touch shouldNormalize:NO];

            /* send moved event */
            SDL_SendMouseMotion(sdlwindow, SDL_TOUCH_MOUSEID, 0, locationInView.x, locationInView.y);
        }

        CGPoint locationInView = [self touchLocation:touch shouldNormalize:YES];
        SDL_SendTouchMotion(touchId, (SDL_FingerID)((size_t)touch),
                            locationInView.x, locationInView.y, pressure);
    }
}

#if TARGET_OS_TV || defined(__IPHONE_9_1)
- (SDL_Scancode)scancodeFromPressType:(UIPressType)presstype
{
    switch (presstype) {
    case UIPressTypeUpArrow:
        return SDL_SCANCODE_UP;
    case UIPressTypeDownArrow:
        return SDL_SCANCODE_DOWN;
    case UIPressTypeLeftArrow:
        return SDL_SCANCODE_LEFT;
    case UIPressTypeRightArrow:
        return SDL_SCANCODE_RIGHT;
    case UIPressTypeSelect:
        /* HIG says: "primary button behavior" */
        return SDL_SCANCODE_SELECT;
    case UIPressTypeMenu:
        /* HIG says: "returns to previous screen" */
        return SDL_SCANCODE_MENU;
    case UIPressTypePlayPause:
        /* HIG says: "secondary button behavior" */
        return SDL_SCANCODE_PAUSE;
    default:
        return SDL_SCANCODE_UNKNOWN;
    }
}

#if !TARGET_OS_TV
/* UIKey.keyCode is a UIKeyboardHIDUsage, and SDL_Scancode is defined from the
   same USB HID usage table, so for the keyboard page the two coincide exactly
   (A is 4 in both, Return 40, LeftControl 224, ...). */
- (SDL_Scancode)scancodeFromKey:(UIKey *)key API_AVAILABLE(ios(13.4))
{
    long usage = key ? key.keyCode : 0;

    if (usage > 0 && usage < SDL_NUM_SCANCODES) {
        return (SDL_Scancode)usage;
    }
    return SDL_SCANCODE_UNKNOWN;
}

/* iOS does not deliver a press for a modifier on its own; it reports which
   modifiers were held on every other press. Diff that against what we last
   saw and synthesise the key events SDL needs to keep its modifier state. */
- (void)syncModifiers:(UIKeyModifierFlags)flags API_AVAILABLE(ios(13.4))
{
    static const UIKeyModifierFlags uiFlags[] = {
        UIKeyModifierShift, UIKeyModifierControl,
        UIKeyModifierAlternate, UIKeyModifierCommand
    };
    static const SDL_Scancode codes[] = {
        SDL_SCANCODE_LSHIFT, SDL_SCANCODE_LCTRL,
        SDL_SCANCODE_LALT, SDL_SCANCODE_LGUI
    };

    for (size_t i = 0; i < sizeof(codes) / sizeof(codes[0]); ++i) {
        BOOL isDown = (flags & uiFlags[i]) != 0;
        BOOL wasDown = (activeModifiers & uiFlags[i]) != 0;
        if (isDown != wasDown) {
            SDL_SendKeyboardKey(isDown ? SDL_PRESSED : SDL_RELEASED, codes[i]);
        }
    }
    activeModifiers = flags;
}
#endif

- (void)handlePresses:(NSSet<UIPress *> *)presses state:(Uint8)state
{
    for (UIPress *press in presses) {
        SDL_Scancode scancode = SDL_SCANCODE_UNKNOWN;

#if !TARGET_OS_TV
        if (@available(iOS 13.4, *)) {
            /* Text entry already reaches SDL through the hidden text field;
               sending scancodes as well would enter every character twice. */
            if (press.key && !SDL_IsTextInputActive()) {
                [self syncModifiers:press.key.modifierFlags];
                scancode = [self scancodeFromKey:press.key];
            }
        }
#endif
        if (scancode == SDL_SCANCODE_UNKNOWN) {
            /* Apple TV remote, and anything older than iOS 13.4. */
            scancode = [self scancodeFromPressType:press.type];
        }
        if (scancode != SDL_SCANCODE_UNKNOWN) {
            SDL_SendKeyboardKey(state, scancode);
        }
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    [self handlePresses:presses state:SDL_PRESSED];

    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    [self handlePresses:presses state:SDL_RELEASED];

    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    for (UIPress *press in presses) {
        SDL_Scancode scancode = [self scancodeFromPressType:press.type];
        SDL_SendKeyboardKey(SDL_RELEASED, scancode);
    }

    [super pressesCancelled:presses withEvent:event];
}

- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    /* This is only called when the force of a press changes. */
    [super pressesChanged:presses withEvent:event];
}
#endif /* TARGET_OS_TV || defined(__IPHONE_9_1) */

#if TARGET_OS_TV
-(void)swipeGesture:(UISwipeGestureRecognizer *)gesture
{
    /* Swipe gestures don't trigger begin states. */
    if (gesture.state == UIGestureRecognizerStateEnded) {
        /* Send arrow key presses for now, as we don't have an external API
         * which better maps to swipe gestures. */
        switch (gesture.direction) {
        case UISwipeGestureRecognizerDirectionUp:
            SDL_SendKeyboardKey(SDL_PRESSED, SDL_SCANCODE_UP);
            SDL_SendKeyboardKey(SDL_RELEASED, SDL_SCANCODE_UP);
            break;
        case UISwipeGestureRecognizerDirectionDown:
            SDL_SendKeyboardKey(SDL_PRESSED, SDL_SCANCODE_DOWN);
            SDL_SendKeyboardKey(SDL_RELEASED, SDL_SCANCODE_DOWN);
            break;
        case UISwipeGestureRecognizerDirectionLeft:
            SDL_SendKeyboardKey(SDL_PRESSED, SDL_SCANCODE_LEFT);
            SDL_SendKeyboardKey(SDL_RELEASED, SDL_SCANCODE_LEFT);
            break;
        case UISwipeGestureRecognizerDirectionRight:
            SDL_SendKeyboardKey(SDL_PRESSED, SDL_SCANCODE_RIGHT);
            SDL_SendKeyboardKey(SDL_RELEASED, SDL_SCANCODE_RIGHT);
            break;
        }
    }
}
#endif /* TARGET_OS_TV */

@end

#endif /* SDL_VIDEO_DRIVER_UIKIT */

/* vi: set ts=4 sw=4 expandtab: */
