// Runs under the system JavaScript for Automation runtime; no application
// activation, Apple Events to another app, or shell interpolation is needed.
ObjC.import('AppKit');
function run(argv) {
    const pb = argv[1] ? $.NSPasteboard.pasteboardWithName(argv[1]) : $.NSPasteboard.generalPasteboard;
    const revision = pb.changeCount;
    const types = ObjC.deepUnwrap(pb.types) || [];
    const raster = ['public.png', 'public.tiff', 'public.jpeg', 'public.heic', 'com.compuserve.gif', 'public.webp'];
    let sawImage = false;
    for (const type of raster.concat(['com.adobe.pdf', 'public.file-url'])) {
        if (types.indexOf(type) < 0) continue;
        let data;
        let flavor = type === 'com.adobe.pdf' ? 'pdf' : 'png';
        if (type === 'public.file-url') {
            const value = pb.stringForType(type);
            if (!value || !value.js) continue;
            const url = $.NSURL.URLWithString(value);
            if (!url.isFileURL) continue;
            const ext = (ObjC.unwrap(url.pathExtension) || '').toLowerCase();
            if (!/^(png|jpe?g|gif|webp|tiff?|heic|bmp|pdf)$/.test(ext)) continue;
            sawImage = true;
            flavor = 'furl';
            data = $.NSData.dataWithContentsOfURL(url);
        } else {
            sawImage = true;
            data = pb.dataForType(type);
        }
        if (!data || !data.length) continue;
        const img = $.NSImage.alloc.initWithData(data);
        if (!img || !img.isValid) continue;
        const bitmap = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
        if (!bitmap || !bitmap.pixelsWide || !bitmap.pixelsHigh) continue;
        const png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
        if (!png || !png.length) continue;
        if (pb.changeCount !== revision) return 'changed';
        if (!png.writeToFileAtomically(argv[0], true)) return 'extract';
        return 'ok:' + flavor;
    }
    if (pb.changeCount !== revision) return 'changed';
    return sawImage ? 'convert' : 'empty';
}
