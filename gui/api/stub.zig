const mer = @import("mer");
const backend = @import("backend");

pub fn render(req: mer.Request) mer.Response {
    const rt = backend.instance orelse {
        return mer.Response.init(.internal_server_error, .json, "{\"error\":\"backend runtime is not initialized\"}");
    };
    return rt.handleApi(req);
}
