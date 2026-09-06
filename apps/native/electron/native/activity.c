#include <node_api.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void graff_show_activity(void *view, const char *json);

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
NAPI_MODULE_INIT() {
    napi_value fn;
    napi_create_function(env, "show", NAPI_AUTO_LENGTH, show, NULL, &fn);
    napi_set_named_property(env, exports, "show", fn);
    napi_create_function(env, "computer", NAPI_AUTO_LENGTH, computer, NULL, &fn);
    napi_set_named_property(env, exports, "computer", fn);
    return exports;
}
