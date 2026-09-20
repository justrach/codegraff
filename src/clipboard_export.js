// Runs under the system JavaScript for Automation runtime; no application
// activation, Apple Events to another app, or shell interpolation is needed.
ObjC.import('AppKit');

function jsString(value) {
    if (!value) return '';
    if (typeof value === 'string') return value;
    if (value.js) return String(value.js);
    const unwrapped = ObjC.unwrap(value);
    return typeof unwrapped === 'string' ? unwrapped : '';
}

function isTrue(flag) {
    if (flag === true || flag === 1) return true;
    if (!flag) return false;
    const unwrapped = ObjC.unwrap(flag);
    return unwrapped === true || unwrapped === 1;
}

function asFileURL(value) {
    const raw = jsString(value);
    if (!raw) return null;
    // Remote http(s) file-url flavors must stay empty, not a network fetch.
    if (/^[a-z][a-z0-9+.-]*:/i.test(raw) && !/^file:/i.test(raw)) return null;
    const url = /^file:/i.test(raw) ? $.NSURL.URLWithString(raw) : $.NSURL.fileURLWithPath(raw);
    if (!url || !isTrue(url.isFileURL)) return null;
    if (isTrue(url.isFileReferenceURL) && url.filePathURL) return url.filePathURL;
    return url;
}

// Telegram/Qt cache files often have no extension. Skip only obvious
// non-images so a copied .txt stays empty instead of convert.
function skipPath(url) {
    const ext = (ObjC.unwrap(url.pathExtension) || '').toLowerCase();
    return /^(txt|html?|json|xml|csv|zip|tar|gz|mp4|mov|m4[av]|mkv|mp3|wav|aiff|docx?|xlsx?|pptx?|ics|vcf|webloc)$/.test(ext);
}

function pngFromData(data) {
    if (!data || !data.length) return null;
    const img = $.NSImage.alloc.initWithData(data);
    if (!img || !img.isValid) return null;
    const bitmap = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
    if (!bitmap || !bitmap.pixelsWide || !bitmap.pixelsHigh) return null;
    const png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
    return png && png.length ? png : null;
}

function run(argv) {
    const pb = argv[1] ? $.NSPasteboard.pasteboardWithName(argv[1]) : $.NSPasteboard.generalPasteboard;
    const revision = pb.changeCount;
    const types = ObjC.deepUnwrap(pb.types) || [];
    let sawImage = false;

    function finish(png, flavor) {
        if (pb.changeCount !== revision) return 'changed';
        if (!png.writeToFileAtomically(argv[0], true)) return 'extract';
        return 'ok:' + flavor;
    }

    // Files first: Telegram/Slack/Finder copy a real path (sometimes without
    // an image suffix) and may also advertise a dummy TIFF/icon.
    const seen = {};
    const files = [];
    function addFile(url, mustExist) {
        if (!url || skipPath(url)) return;
        const path = jsString(url.path);
        if (!path || seen[path]) return;
        if (mustExist && !$.NSFileManager.defaultManager.fileExistsAtPath(path)) return;
        seen[path] = true;
        files.push(url);
    }
    if (types.indexOf('public.file-url') >= 0) {
        const value = pb.stringForType('public.file-url');
        const raw = value && value.js ? String(value.js) : jsString(value);
        if (/^file:/i.test(raw)) addFile(asFileURL(value), false);
    }
    if (types.indexOf('NSFilenamesPboardType') >= 0) {
        const names = ObjC.deepUnwrap(pb.propertyListForType('NSFilenamesPboardType')) || [];
        if (Array.isArray(names) && names.length && !/^[a-z][a-z0-9+.-]*:/i.test(String(names[0])))
            addFile($.NSURL.fileURLWithPath(String(names[0])), true);
    }

    for (const url of files) {
        sawImage = true;
        const png = pngFromData($.NSData.dataWithContentsOfURL(url));
        if (png) return finish(png, 'furl');
    }

    const raster = ['public.png', 'public.tiff', 'public.jpeg', 'public.heic', 'com.compuserve.gif', 'public.webp', 'com.adobe.pdf'];
    for (const type of raster) {
        if (types.indexOf(type) < 0) continue;
        sawImage = true;
        const png = pngFromData(pb.dataForType(type));
        if (png) return finish(png, type === 'com.adobe.pdf' ? 'pdf' : 'png');
    }
    if (pb.changeCount !== revision) return 'changed';
    return sawImage ? 'convert' : 'empty';
}
