// Test-only observer loaded into Electron; it never ships in the native bridge.
#import <AppKit/AppKit.h>
#include <node_api.h>
#include <string.h>

static NSWindow *windowArg(napi_env env, napi_callback_info info) {
    size_t argc = 1, size = 0;
    napi_value arg;
    void *bytes = NULL, *pointer = NULL;
    if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok || argc != 1 ||
        napi_get_buffer_info(env, arg, &bytes, &size) != napi_ok || size != sizeof(pointer)) {
        napi_throw_type_error(env, NULL, "Expected a native window handle");
        return nil;
    }
    memcpy(&pointer, bytes, sizeof(pointer));
    return [(__bridge NSView *)pointer window];
}

static napi_value json(napi_env env, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    napi_value result;
    napi_create_string_utf8(env, data.bytes, data.length, &result);
    return result;
}

static napi_value inspect(napi_env env, napi_callback_info info) {
    NSWindow *window = windowArg(env, info);
    if (!window) return NULL;
    NSWindow *sheet = window.attachedSheet;
    return json(env, @{
        @"active": @(NSApp.active), @"screens": @(NSScreen.screens.count),
        @"visible": @(window.visible), @"key": @(window.keyWindow),
        @"sheetAttached": @(sheet != nil), @"sheetVisible": @(sheet.visible),
        @"sheetKey": @(sheet.keyWindow), @"sheetTitle": sheet.title ?: @"",
        @"sheetWidth": @(sheet.frame.size.width), @"sheetHeight": @(sheet.frame.size.height)
    });
}

static napi_value pressReturn(napi_env env, napi_callback_info info) {
    NSWindow *window = windowArg(env, info);
    if (!window) return NULL;
    NSWindow *target = window.attachedSheet ?: window;
    // Exercise AppKit's default-button routing, without global event injection.
    for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        NSEvent *event = [NSEvent keyEventWithType:type.unsignedIntegerValue
            location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
            windowNumber:target.windowNumber context:nil characters:@"\r"
            charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [NSApp sendEvent:event];
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

NAPI_MODULE_INIT() {
    napi_property_descriptor methods[] = {
        { "inspect", NULL, inspect, NULL, NULL, NULL, napi_default, NULL },
        { "pressReturn", NULL, pressReturn, NULL, NULL, NULL, napi_default, NULL },
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}
