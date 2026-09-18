#include <node_api.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void graff_show_activity(void *view, const char *json);
extern int graff_install_pane_glass(void *view);
extern void graff_notch_update(const char *json);
extern void graff_notch_hide(void);
extern char *graff_notch_inspect(void);
extern char *graff_notch_layout_json(int cells, int hovering);
extern void graff_notch_set_click(void (*handler)(int));

static napi_threadsafe_function notch_click = NULL;
void graff_notch_emit_click(int id) {
    if (notch_click) napi_call_threadsafe_function(notch_click, (void *)(intptr_t)id, napi_tsfn_nonblocking);
}
static void notch_click_js(napi_env env, napi_value js_cb, void *ctx, void *data) {
    napi_value argv, recv;
    if (!env || !js_cb) return;
    napi_create_int32(env, (int)(intptr_t)data, &argv);
    napi_get_undefined(env, &recv);
    napi_call_function(env, recv, js_cb, 1, &argv, NULL);
}

static napi_value show(napi_env env, napi_callback_info info) {
    size_t argc = 2, handle_size = 0, json_size = 0;
    napi_value args[2], result;
    void *handle_data = NULL, *view = NULL;
    napi_get_undefined(env, &result);
    if (napi_get_cb_info(env, info, &argc, args, NULL, NULL) != napi_ok || argc != 2 ||
        napi_get_buffer_info(env, args[0], &handle_data, &handle_size) != napi_ok ||
        handle_size != sizeof(view) ||
        napi_get_value_string_utf8(env, args[1], NULL, 0, &json_size) != napi_ok || json_size > 4096) {
        napi_throw_type_error(env, NULL, "Expected a native window handle and activity JSON");
        return result;
    }
    char *json = calloc(json_size + 1, 1);
    if (!json) { napi_throw_error(env, NULL, "Out of memory"); return result; }
    napi_get_value_string_utf8(env, args[1], json, json_size + 1, &json_size);
    memcpy(&view, handle_data, sizeof(view));
    graff_show_activity(view, json);
    free(json);
    return result;
}

extern char *graff_computer_command(const char *json);
static napi_value computer(napi_env env, napi_callback_info info) {
    size_t argc = 1, size = 0;
    napi_value arg, result;
    napi_get_undefined(env, &result);
    if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, arg, NULL, 0, &size) != napi_ok || size > 64000) {
        napi_throw_type_error(env, NULL, "Expected bounded computer command JSON"); return result;
    }
    char *input = calloc(size + 1, 1);
    if (!input) { napi_throw_error(env, NULL, "Out of memory"); return result; }
    napi_get_value_string_utf8(env, arg, input, size + 1, &size);
    char *output = graff_computer_command(input);
    free(input);
    if (output) { napi_create_string_utf8(env, output, NAPI_AUTO_LENGTH, &result); free(output); }
    return result;
}
static napi_value glass(napi_env env, napi_callback_info info) {
    size_t argc = 1, handle_size = 0;
    napi_value args[1], result;
    void *handle_data = NULL, *view = NULL;
    napi_get_undefined(env, &result);
    if (napi_get_cb_info(env, info, &argc, args, NULL, NULL) != napi_ok || argc != 1 ||
        napi_get_buffer_info(env, args[0], &handle_data, &handle_size) != napi_ok ||
        handle_size != sizeof(view)) {
        napi_throw_type_error(env, NULL, "Expected a native window handle");
        return result;
    }
    memcpy(&view, handle_data, sizeof(view));
    napi_create_int32(env, graff_install_pane_glass(view), &result);
    return result;
}
static napi_value take_string(napi_env env, char *text) {
    napi_value result;
    if (text) { napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &result); free(text); }
    else napi_get_null(env, &result);
    return result;
}
static napi_value update_notch(napi_env env, napi_callback_info info) {
    size_t argc = 1, size = 0;
    napi_value arg, result;
    napi_get_undefined(env, &result);
    if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, arg, NULL, 0, &size) != napi_ok || size > 16000) {
        napi_throw_type_error(env, NULL, "Expected bounded observer JSON"); return result;
    }
    char *json = calloc(size + 1, 1);
    if (!json) { napi_throw_error(env, NULL, "Out of memory"); return result; }
    napi_get_value_string_utf8(env, arg, json, size + 1, &size);
    graff_notch_update(json);
    free(json);
    return result;
}
static napi_value hide_notch(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_undefined(env, &result);
    graff_notch_hide();
    return result;
}
static napi_value inspect_notch(napi_env env, napi_callback_info info) {
    return take_string(env, graff_notch_inspect());
}
static napi_value layout_notch(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    int32_t cells = 1, hovering = 0;
    if (napi_get_cb_info(env, info, &argc, args, NULL, NULL) != napi_ok) {
        napi_value result; napi_get_null(env, &result); return result;
    }
    if (argc > 0) napi_get_value_int32(env, args[0], &cells);
    if (argc > 1) napi_get_value_int32(env, args[1], &hovering);
    return take_string(env, graff_notch_layout_json(cells, hovering));
}
static napi_value on_notch_click(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg, result, name;
    napi_get_undefined(env, &result);
    napi_valuetype type;
    if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok || argc != 1 ||
        napi_typeof(env, arg, &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, NULL, "Expected a click callback"); return result;
    }
    if (notch_click) { napi_release_threadsafe_function(notch_click, napi_tsfn_abort); notch_click = NULL; }
    napi_create_string_utf8(env, "graff-notch-click", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, arg, NULL, name, 0, 1, NULL, NULL, NULL, notch_click_js, &notch_click);
    return result;
}
NAPI_MODULE_INIT() {
    graff_notch_set_click(graff_notch_emit_click);
    napi_value fn;
    napi_create_function(env, "show", NAPI_AUTO_LENGTH, show, NULL, &fn);
    napi_set_named_property(env, exports, "show", fn);
    napi_create_function(env, "computer", NAPI_AUTO_LENGTH, computer, NULL, &fn);
    napi_set_named_property(env, exports, "computer", fn);
    napi_create_function(env, "glass", NAPI_AUTO_LENGTH, glass, NULL, &fn);
    napi_set_named_property(env, exports, "glass", fn);
    napi_create_function(env, "updateNotch", NAPI_AUTO_LENGTH, update_notch, NULL, &fn);
    napi_set_named_property(env, exports, "updateNotch", fn);
    napi_create_function(env, "hideNotch", NAPI_AUTO_LENGTH, hide_notch, NULL, &fn);
    napi_set_named_property(env, exports, "hideNotch", fn);
    napi_create_function(env, "inspectNotch", NAPI_AUTO_LENGTH, inspect_notch, NULL, &fn);
    napi_set_named_property(env, exports, "inspectNotch", fn);
    napi_create_function(env, "layoutNotch", NAPI_AUTO_LENGTH, layout_notch, NULL, &fn);
    napi_set_named_property(env, exports, "layoutNotch", fn);
    napi_create_function(env, "onNotchClick", NAPI_AUTO_LENGTH, on_notch_click, NULL, &fn);
    napi_set_named_property(env, exports, "onNotchClick", fn);
    return exports;
}
