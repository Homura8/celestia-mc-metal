// Celestia Metal slot mapping for ported Metal Shaders (P0/P1).
// RenderPearl vertex buffers occupy buffer(16..23), game UBOs occupy buffer(0..14),
// and push constants occupy buffer(15), so shade globals sit in buffer(24..30).
#ifndef CELESTIA_SHADE_SLOTS
#define CELESTIA_SHADE_SLOTS

#define CM_SHADE_BUF_FRAME     24
#define CM_SHADE_BUF_LOOK      25
#define CM_SHADE_BUF_GPU       26
#define CM_SHADE_BUF_RESOURCES 27
#define CM_SHADE_BUF_WATER     28
#define CM_SHADE_BUF_DYNLIGHTS 29

#define CM_SHADE_TEX_SHADOW       16
#define CM_SHADE_TEX_SKY_LUT      17
#define CM_SHADE_TEX_WATER_SCENE  18
#define CM_SHADE_TEX_WATER_DEPTH  19
#define CM_SHADE_TEX_WATER_WAVES  20
#define CM_SHADE_TEX_WATER_PYR    21
#define CM_SHADE_TEX_WATER_DETAIL 22
#define CM_SHADE_TEX_DL_VIS       23
#define CM_SHADE_TEX_DL_IRR       24
#define CM_SHADE_TEX_DL_DIR       25

// Dynamic lights (P6a): extra shading-function parameters / arguments, empty when the module is off.
#ifdef SHADE_DYNLIGHT
#define CEL_DL_PARAMS , constant ShadeDynLights &dl, texture3d<half> dlIrr, texture3d<half> dlDir
#define CEL_DL_ARGS , celDL, celDlIrr, celDlDir
#else
#define CEL_DL_PARAMS
#define CEL_DL_ARGS
#endif

#define CM_SHADE_SAMP_SHADOW      12
#define CM_SHADE_SAMP_LINEAR      13

#endif
