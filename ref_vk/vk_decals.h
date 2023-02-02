
#include "vk_core.h"
#include "vk_cvar.h"
#include "vk_common.h"
#include "vk_textures.h"
#include "vk_renderstate.h"
#include "vk_overlay.h"
#include "vk_scene.h"
#include "vk_framectl.h"
#include "vk_lightmap.h"
#include "vk_sprite.h"
#include "vk_studio.h"
#include "vk_beams.h"
#include "vk_brush.h"

#include "xash3d_types.h"
#include "com_strings.h"

void R_DecalShoot( int textureIndex, int entityIndex, int modelIndex, vec3_t pos, int flags, float scale );
void R_DecalRemoveAll( int texture );
int R_CreateDecalList( struct decallist_s *pList );
void R_ClearAllDecals( void );
void R_ClearDecals( void );
void DrawSingleDecal( decal_t *pDecal, msurface_t *fa );
float* R_DecalSetupVerts( decal_t* pDecal, msurface_t* surf, int texture, int* outCount );
void R_EntityRemoveDecals( model_t *mod );
void DrawDecalsBatch( void );
void DrawSurfaceDecals( msurface_t* fa, qboolean single, qboolean reverse );
