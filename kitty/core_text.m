/*
 * core_text.c
 * Copyright (C) 2017 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#include "data-types.h"
#include <structmember.h>
#include <stdint.h>
#include <math.h>
#import <CoreGraphics/CGBitmapContext.h>
#import <CoreText/CTFont.h>
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>

typedef struct {
    PyObject_HEAD

    unsigned int units_per_em;
    float ascent, descent, leading, underline_position, underline_thickness, point_sz, scaled_point_sz, char_width, char_height, cap_height;
    CTFontRef font;
    PyObject *family_name, *full_name, *postscript_name;
} Face;


static PyObject*
convert_cfstring(CFStringRef src) {
#define SZ 2048
    static char buf[SZ+2] = {0};
    if(!CFStringGetCString(src, buf, SZ, kCFStringEncodingUTF8)) { PyErr_SetString(PyExc_ValueError, "Failed to convert CFString"); return NULL; }
    return PyUnicode_FromString(buf);
#undef SZ
}


static PyObject*
new(PyTypeObject *type, PyObject *args, PyObject UNUSED *kwds) {
    Face *self;
    int bold, italic, monospace;
    char *cfamily;
    float point_sz, dpi;
    if(!PyArg_ParseTuple(args, "spppff", &cfamily, &bold, &italic, &monospace, &point_sz, &dpi)) return NULL;
    NSString *family = [[NSString alloc] initWithCString:cfamily encoding:NSUTF8StringEncoding];
    if (family == NULL) return PyErr_NoMemory();
    self = (Face *)type->tp_alloc(type, 0);
    if (self) {
        CTFontSymbolicTraits symbolic_traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0) | (monospace ? kCTFontMonoSpaceTrait : 0);
        NSDictionary *font_traits = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:symbolic_traits] forKey:(NSString *)kCTFontSymbolicTrait];
        NSDictionary *font_attributes = [NSDictionary dictionaryWithObjectsAndKeys:family, kCTFontFamilyNameAttribute, font_traits, kCTFontTraitsAttribute, nil];
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((CFDictionaryRef)font_attributes);
        if (descriptor) {
            self->point_sz = point_sz;
            self->scaled_point_sz = (dpi / 72.0) * point_sz;
            self->font = CTFontCreateWithFontDescriptor(descriptor, self->scaled_point_sz, NULL);
            CFRelease(descriptor);
            if (!self->font) { Py_CLEAR(self); PyErr_SetString(PyExc_ValueError, "Failed to create CTFont object"); }
            else {
                self->units_per_em = CTFontGetUnitsPerEm(self->font);
                self->ascent = CTFontGetAscent(self->font);
                self->descent = CTFontGetDescent(self->font);
                self->leading = CTFontGetLeading(self->font);
                self->cap_height = CTFontGetCapHeight(self->font);
                self->underline_position = CTFontGetUnderlinePosition(self->font);
                self->underline_thickness = CTFontGetUnderlineThickness(self->font);
                self->scaled_point_sz = CTFontGetSize(self->font);
                self->family_name = convert_cfstring(CTFontCopyFamilyName(self->font));
                self->full_name = convert_cfstring(CTFontCopyFullName(self->font));
                self->postscript_name = convert_cfstring(CTFontCopyPostScriptName(self->font));
                CGRect rect = CTFontGetBoundingBox(self->font);
                self->char_width = self->leading + (rect.size.width / 2);
                self->char_height = self->ascent + self->descent;
                if (self->family_name == NULL || self->full_name == NULL || self->postscript_name == NULL) { Py_CLEAR(self); }
            }
        } else {
            Py_CLEAR(self);
            PyErr_NoMemory();
        }
    }
    [ family release ];
    return (PyObject*)self;
}


static void
dealloc(Face* self) {
    if (self->font) CFRelease(self->font);
    Py_CLEAR(self->family_name); Py_CLEAR(self->full_name); Py_CLEAR(self->postscript_name);
    Py_TYPE(self)->tp_free((PyObject*)self);
}

static void
encode_utf16_pair(uint32_t character, unichar *units) {
    unsigned int code;
    assert(0x10000 <= character && character <= 0x10FFFF);
    code = (character - 0x10000);
    units[0] = 0xD800 | (code >> 10);
    units[1] = 0xDC00 | (code & 0x3FF);
}

static PyObject*
has_char(Face *self, PyObject *args) {
#define has_char_doc "True iff this font has glyphs for the specified character"
    int ch, count = 1;
    unichar chars[2] = {0};
    CGGlyph glyphs[2] = {0};
    if (!PyArg_ParseTuple(args, "C", &ch)) return NULL;
    if (ch <= 0xffff) chars[0] = (unichar)ch;
    else { encode_utf16_pair(ch, chars); count = 2; }
    PyObject *ret = (CTFontGetGlyphsForCharacters(self->font, chars, glyphs, count)) ? Py_True : Py_False;
    Py_INCREF(ret);
    return ret;
}

static PyObject*
font_units_to_pixels(Face *self, PyObject *args) {
#define font_units_to_pixels_doc "Convert the specified value from font units to pixels at the current font size"
    double x;
    if (!PyArg_ParseTuple(args, "d", &x)) return NULL;
    x *= self->scaled_point_sz / self->units_per_em;
    return Py_BuildValue("i", (int)ceil(x));
}

static PyObject*
cell_size(Face *self) {
#define cell_size_doc "Return the best cell size for this font based on the advances for the ASCII chars from 32 to 127"
    return Py_BuildValue("II", (int)ceil(self->char_width), (int)ceil(self->char_height - 1));
#undef count
}

static PyObject*
render_char(Face *self, PyObject *args) {
#define render_char_doc "Render the specified character into the specified buffer. Combining unicode chars should be handled automatically (I hope)"
    char *s;
    unsigned int width, height;
    PyObject *pbuf;
    CGColorSpaceRef color_space = NULL;
    CGContextRef ctx = NULL;
    CTFontRef font = NULL;
    if (!PyArg_ParseTuple(args, "esIIO!", "UTF-8", &s, &width, &height, &PyLong_Type, &pbuf)) return NULL;
    uint8_t *buf = (uint8_t*)PyLong_AsVoidPtr(pbuf);
    CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    if (!str) return PyErr_NoMemory();
    CGGlyph glyphs[10] = {0};
    unichar chars[10] = {0};
    CFRange range = CFRangeMake(0, CFStringGetLength(str));
    CFStringGetCharacters(str, range, chars);
    font = CTFontCreateForString(self->font, str, range);
    if (font == NULL) { PyErr_SetString(PyExc_ValueError, "Failed to find fallback font"); goto end; }
    CTFontGetGlyphsForCharacters(font, chars, glyphs, range.length);
    color_space = CGColorSpaceCreateDeviceGray();
    if (color_space == NULL) { PyErr_NoMemory(); goto end; }
    ctx = CGBitmapContextCreate(buf, width, height, 8, width, color_space, (kCGBitmapAlphaInfoMask & kCGImageAlphaNone));
    if (ctx == NULL) { PyErr_SetString(PyExc_ValueError, "Failed to create bitmap context"); goto end; }
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, true);  // sub-pixel antialias
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1); // white glyphs
    CGAffineTransform transform = CGAffineTransformIdentity;
    CGContextSetTextDrawingMode(ctx, kCGTextFill);
    CGGlyph glyph = glyphs[0];
    if (glyph) {
        // TODO: Scale the glyph if its bbox is larger than the image by using a non-identity transform
        /* CGRect rect = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, glyphs, 0, 1); */
        CGContextSetTextMatrix(ctx, transform);
        CGContextSetTextPosition(ctx, self->leading, self->descent);
        CTFontDrawGlyphs(font, &glyph, &CGPointZero, 1, ctx);

        // TODO: Move this to behind a setting, it renders the text a bit fatter which I really like.
        CGContextTranslateCTM(ctx, 1, 0);
        CTFontDrawGlyphs(font, &glyph, &CGPointZero, 1, ctx);
        CGContextTranslateCTM(ctx, -1, 0);
    }

end:
    CFRelease(str);
    if (ctx) CGContextRelease(ctx);
    if (color_space) CGColorSpaceRelease(color_space);
    if (font && font != self->font) CFRelease(font);
    if (PyErr_Occurred()) return NULL;
    Py_RETURN_NONE;
}

static PyObject *
repr(Face *self) {
    char buf[400] = {0};
    snprintf(buf, sizeof(buf)/sizeof(buf[0]), "ascent=%.1f, descent=%.1f, leading=%.1f, point_sz=%.1f, scaled_point_sz=%.1f, underline_position=%.1f underline_thickness=%.1f", 
        (self->ascent), (self->descent), (self->leading), (self->point_sz), (self->scaled_point_sz), (self->underline_position), (self->underline_thickness));
    return PyUnicode_FromFormat(
        "Face(family=%U, full_name=%U, postscript_name=%U, units_per_em=%u, %s)",
        self->family_name, self->full_name, self->postscript_name, self->units_per_em, buf
    );
}


// Boilerplate {{{

static PyMemberDef members[] = {
#define MEM(name, type) {#name, type, offsetof(Face, name), READONLY, #name}
    MEM(units_per_em, T_UINT),
    MEM(point_sz, T_FLOAT),
    MEM(scaled_point_sz, T_FLOAT),
    MEM(ascent, T_FLOAT),
    MEM(descent, T_FLOAT),
    MEM(leading, T_FLOAT),
    MEM(underline_position, T_FLOAT),
    MEM(underline_thickness, T_FLOAT),
    MEM(family_name, T_OBJECT),
    MEM(full_name, T_OBJECT),
    MEM(postscript_name, T_OBJECT),
    {NULL}  /* Sentinel */
};

static PyMethodDef methods[] = {
    METHOD(has_char, METH_VARARGS)
    METHOD(cell_size, METH_NOARGS)
    METHOD(font_units_to_pixels, METH_VARARGS)
    METHOD(render_char, METH_VARARGS)
    {NULL}  /* Sentinel */
};


PyTypeObject Face_Type = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "fast_data_types.CTFace",
    .tp_basicsize = sizeof(Face),
    .tp_dealloc = (destructor)dealloc, 
    .tp_flags = Py_TPFLAGS_DEFAULT,        
    .tp_doc = "CoreText Font face",
    .tp_methods = methods,
    .tp_members = members,
    .tp_new = new,                
    .tp_repr = (reprfunc)repr,
};


int 
init_CoreText(PyObject *module) {
    if (PyType_Ready(&Face_Type) < 0) return 0;
    if (PyModule_AddObject(module, "CTFace", (PyObject *)&Face_Type) != 0) return 0;
    return 1;
}


// }}}
