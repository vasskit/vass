// stb_image (public domain / MIT, https://github.com/nothings/stb) compiled as
// one translation unit. Only the formats Vass decodes are built in.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_MAX_DIMENSIONS 16384
#include "stb_image.h"
