
/*
 * Copyright (c) 2008 - 2009 NVIDIA Corporation.  All rights reserved.
 *
 * NVIDIA Corporation and its licensors retain all intellectual property and proprietary
 * rights in and to this software, related documentation and any modifications thereto.
 * Any use, reproduction, disclosure or distribution of this software and related
 * documentation without an express license agreement from NVIDIA Corporation is strictly
 * prohibited.
 *
 * TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, THIS SOFTWARE IS PROVIDED *AS IS*
 * AND NVIDIA AND ITS SUPPLIERS DISCLAIM ALL WARRANTIES, EITHER EXPRESS OR IMPLIED,
 * INCLUDING, BUT NOT LIMITED TO, IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  IN NO EVENT SHALL NVIDIA OR ITS SUPPLIERS BE LIABLE FOR ANY
 * SPECIAL, INCIDENTAL, INDIRECT, OR CONSEQUENTIAL DAMAGES WHATSOEVER (INCLUDING, WITHOUT
 * LIMITATION, DAMAGES FOR LOSS OF BUSINESS PROFITS, BUSINESS INTERRUPTION, LOSS OF
 * BUSINESS INFORMATION, OR ANY OTHER PECUNIARY LOSS) ARISING OUT OF THE USE OF OR
 * INABILITY TO USE THIS SOFTWARE, EVEN IF NVIDIA HAS BEEN ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGES
 */


#include <optix.h>
#include <optix_device.h>
#include <optixu/optixu_math_namespace.h>
#include <optixu/optixu_matrix_namespace.h>
#include <optixu/optixu_aabb_namespace.h>

#include "path_tracer.h"
#include "random.h"

#include "GLSL_Functions.h"
#include "DistanceFieldMaths.h"
#include "DistanceFieldPrimitives.h"
#include "DistanceFieldAdvancedPrimitives.h"
#include "DistanceFieldTraps.h"

using namespace optix;

#define USE_DEBUG_EXCEPTIONS 0

// References:
// [1] Hart, J. C., Sandin, D. J., and Kauffman, L. H. 1989. Ray tracing deterministic 3D fractals
// [2] http://www.devmaster.net/forums/showthread.php?t=4448

rtBuffer<float4, 2>              output_buffer;
rtBuffer<float3, 2>              output_buffer_nrm;
rtBuffer<float3, 2>              output_buffer_world;
rtBuffer<float, 2>              output_buffer_depth;

rtDeclareVariable( float3, eye, , );
rtDeclareVariable( float,  alpha , , );
rtDeclareVariable( float,  delta , , );
rtDeclareVariable( float,  DEL , , );
rtDeclareVariable( uint,   max_iterations , , );    // max iterations for divergence determination
rtDeclareVariable( float, global_t, , );          // Global time

rtDeclareVariable(optix::Ray, ray, rtCurrentRay, );

// julia set object outputs this
rtDeclareVariable(float3, normal, attribute normal, );
rtDeclareVariable(unsigned int, iterations, attribute iterations, );
rtDeclareVariable(float, smallestdistance, attribute smallestdistance, );

// sphere outputs this
rtDeclareVariable(float3, shading_normal, attribute shading_normal, );
rtDeclareVariable(float3, shading_normal2, attribute shading_normal2, );
rtDeclareVariable(float3, geometric_normal, attribute geometric_normal, );


rtDeclareVariable(uint2, launch_index, rtLaunchIndex, );
rtDeclareVariable(uint2, launch_dim,   rtLaunchDim, );
rtDeclareVariable(float, time_view_scale, , ) = 1e-6f;

rtDeclareVariable(Matrix4x4, normalmatrix, , );
rtDeclareVariable(float3,        U, , );
rtDeclareVariable(float3,        V, , );
rtDeclareVariable(float3,        W, , );
rtDeclareVariable(float3,        bad_color, , );
rtDeclareVariable(float,         scene_epsilon, , );

rtDeclareVariable(rtObject,                         top_object, , );
rtDeclareVariable(rtObject,                         top_shadower, , );
rtDeclareVariable(float, isect_t, rtIntersectionDistance, );
//rtDeclareVariable(PerRayData_radiance, prd_radiance, rtPayload, );
//rtDeclareVariable(PerRayData_shadow,   prd_shadow,   rtPayload, );

rtDeclareVariable(unsigned int,  pathtrace_ray_type, , );
rtDeclareVariable(unsigned int,  pathtrace_shadow_ray_type, , );
rtDeclareVariable(unsigned int,  rr_begin_depth, , );

rtDeclareVariable(unsigned int,  frame_number, , );
rtDeclareVariable(unsigned int,  sqrt_num_samples, , );

rtDeclareVariable(float,      t_hit,        rtIntersectionDistance, );


struct PerRayData_pathtrace
{
  float4 result;
  float3 result_nrm;
  float3 result_world;
  float result_depth;

  float3 origin;
  float3 radiance;
  float3 direction;
  float3 attenuation;
  unsigned int seed;
  int depth;
  int countEmitted;
  int done;
  int inside;

  unsigned int iteration;
};

struct PerRayData_pathtrace_shadow
{
  bool inShadow;
  unsigned int depth;
  float attenuation;
};

rtDeclareVariable(PerRayData_pathtrace, current_prd, rtPayload, );
rtDeclareVariable(PerRayData_pathtrace, prd_radiance, rtPayload, );

//struct PerRayData_shadow
//{
//  float3 attenuation;
//  bool inShadow;
//};

RT_PROGRAM void exception()
{
  output_buffer[launch_index] = make_float4(bad_color, 0.0f);
  output_buffer_nrm[launch_index] = make_float3(0.0, 0.0, 0.0);
  output_buffer_world[launch_index] = make_float3(0.0, 0.0, 0.0);
  output_buffer_depth[launch_index] = RT_DEFAULT_MAX;

#if USE_DEBUG_EXCEPTIONS
  const unsigned int code = rtGetExceptionCode();
  rtPrintf("Exception code 0x%X at (%d, %d)\n", code, launch_index.x, launch_index.y);
#endif
}


RT_PROGRAM void pathtrace_camera()
{
    size_t2 screen = output_buffer.size();

    float2 inv_screen = 1.0f/make_float2(screen) * 2.f;
    float2 pixel = (make_float2(launch_index)) * inv_screen - 1.f;

    float2 jitter_scale = inv_screen / sqrt_num_samples;
    unsigned int samples_per_pixel = sqrt_num_samples*sqrt_num_samples;

    // Store accumulated radiance, world position, normal and depth
    float4 result = make_float4(0.0f);
    float3 normal = make_float3(0.0f);
    float3 world = make_float3(0.0f);
    float depth = 0.0f;

    // Bounce GI
    unsigned int seed = tea<4>(screen.x * launch_index.y + launch_index.x, frame_number);
    do
    {
        unsigned int x = samples_per_pixel % sqrt_num_samples;
        unsigned int y = samples_per_pixel / sqrt_num_samples;
        float2 jitter = make_float2(x-rnd(seed), y-rnd(seed));
        float2 d = pixel + jitter*jitter_scale;
        float3 ray_origin = eye;
        float3 ray_direction = normalize(d.x*U + d.y*V + W);

        ray_direction = make_float3((make_float4(ray_direction, 1.0) * normalmatrix));
//        ray_direction = normalize(ray_direction);

        PerRayData_pathtrace prd;
        prd.result = make_float4(0.f);
        prd.result_nrm = make_float3(0.0f);
        prd.result_world = make_float3(0.0f);
        prd.result_depth = 0.0f;
        prd.attenuation = make_float3(1.0);
        prd.radiance = make_float3(0.0);
        prd.countEmitted = true;
        prd.done = false;
        prd.seed = seed;
        prd.depth = 0;
        prd.iteration = 0;

        Ray ray = make_Ray(ray_origin, ray_direction, pathtrace_ray_type, scene_epsilon, RT_DEFAULT_MAX);
        rtTrace(top_object, ray, prd);

//        prd.result_nrm.x = abs(prd.result_nrm.x);
//        prd.result_nrm.y = abs(prd.result_nrm.y);
//        prd.result_nrm.z = abs(prd.result_nrm.z);

        result += prd.result;
        normal += prd.result_nrm;
        world += prd.result_world;
        depth += prd.result_depth;

        seed = prd.seed;
    } while (--samples_per_pixel);

    float4 pixel_color = result/(sqrt_num_samples*sqrt_num_samples);
    float3 pixel_color_normal = normal/(sqrt_num_samples*sqrt_num_samples);
    float3 pixel_color_world = world/(sqrt_num_samples*sqrt_num_samples);
    float pixel_color_depth = depth/(sqrt_num_samples*sqrt_num_samples);

    // Smoothly blend with previous frames value
    if (frame_number > 1){
        float a = 1.0f / (float)frame_number;
        float b = ((float)frame_number - 1.0f) * a;

        float4 old_color = output_buffer[launch_index];
        output_buffer[launch_index] = a * pixel_color + b * old_color;

        float3 old_nrm = output_buffer_nrm[launch_index];
        output_buffer_nrm[launch_index] = a * pixel_color_normal + b * old_nrm;

        float3 old_world = output_buffer_world[launch_index];
        output_buffer_world[launch_index] = a * pixel_color_world + b * old_world;

        float old_depth = output_buffer_depth[launch_index];
        output_buffer_depth[launch_index] = a * pixel_color_depth + b * old_depth;
    }
    else
    {
        output_buffer[launch_index] = pixel_color;
        output_buffer_nrm[launch_index] = pixel_color_normal;
        output_buffer_world[launch_index] = pixel_color_world;
        output_buffer_depth[launch_index] = pixel_color_depth;
    }
}






//// Geometric orbit trap. Creates the 'cube' look.
//float trap(vec3 p){
//	return  length(p.x-0.5-0.5*sin(time/10.0)); // <- cube forms
//	//return  length(p.x-1.0);
//	//return length(p.xz-vec2(1.0,1.0))-0.05; // <- tube forms
//	//return length(p); // <- no trap
//}

RT_PROGRAM void intersect(int primIdx)
{
  normal = make_float3(0,0,0);

  bool shouldSphereTrace = false;
  float tmin, tmax;
  tmin = 0;
  tmax = RT_DEFAULT_MAX;

  const float sqRadius = 100;

  float distance;
  if( insideSphere(ray.origin, make_float3(0,0,0), sqRadius, &distance) )
  {
      tmin = 0;
      tmax = RT_DEFAULT_MAX;
      shouldSphereTrace = true;
  }
  else
  {
      // Push hit to nearest point on sphere
      if( intersectBoundingSphere(ray.origin, ray.direction, sqRadius, tmin, tmax) )
      {
          shouldSphereTrace = true;
      }
  }


  if(shouldSphereTrace)
  {
//      Mandelbulb sdf(max_iterations);
      MengerSponge sdf(max_iterations);
//      IFSTest sdf(max_iterations);
      sdf.setTime(global_t);
      sdf.evalParameters();

//    JuliaSet distance( max_iterations );
    //distance.m_max_iterations = 64;

    // === Raymarching (Sphere Tracing) Procedure ===
    float3 ray_direction = ray.direction;
    float3 eye = ray.origin;
//    eye.y -= global_t * 1.2f;
    float3 x = eye + tmin * ray_direction;

    float dist_from_origin = tmin;

    const float3 point = make_float3(.0f);

    SphereTrap trap;

    // Compute epsilon using equation (16) of [1].
    //float epsilon = max(0.000001f, alpha * powf(dist_from_origin, delta));
    //const float epsilon = 1e-3f;
    const float epsilon = 0.001;

    //http://blog.hvidtfeldts.net/index.php/2011/09/distance-estimated-3d-fractals-v-the-mandelbulb-different-de-approximations/
    float fudgeFactor = 0.99;

    // float t = tmin;//0.0;
    // const int maxSteps = 128;
    float dist = 0;

    for( unsigned int i = 0; i < 800; ++i )
    {
      dist = sdf.evalDistance(x);

      // Step along the ray and accumulate the distance from the origin.
      x += dist * ray_direction;
      dist_from_origin += dist * fudgeFactor;

      // Check if we're close enough or too far.
      if( dist < epsilon || dist_from_origin > tmax  )
      {
          iterations = i;
//          rtPrintf("%f, %f, %f\n", ray.origin.x, ray.origin.y, ray.origin.z);
          break;
      }

//      orbitdist = min( orbitdist, lengthSqr(x - point) );
      trap.trap(x);

    }

    // Found intersection?
    if( dist < epsilon )
    {
      if( rtPotentialIntersection( dist_from_origin)  )
      {
        sdf.setMaxIterations(14); // more iterations for normal estimate, to fake some more detail
        normal = calculateNormal(sdf, x, DEL);

        geometric_normal = normal;
        shading_normal = normal;

        smallestdistance = trap.getTrapValue();
        rtReportIntersection( 0 );
      }
    }
  }
}

RT_PROGRAM void bounds (int, float result[6])
{
  optix::Aabb* aabb = (optix::Aabb*)result;
  const float sz = 1.4f;
  aabb->m_min = make_float3(-sz);
  aabb->m_max = make_float3(sz);
}



rtBuffer<ParallelogramLight>     lights;

rtDeclareVariable(float3, emission_color, , );
RT_PROGRAM void diffuseEmitter(){
    if(current_prd.countEmitted){
        current_prd.result = make_float4(emission_color, 1.0f);
        current_prd.result_nrm = make_float3(0);
    }
    current_prd.done = true;
}

rtDeclareVariable(PerRayData_pathtrace_shadow, current_prd_shadow, rtPayload, );

RT_PROGRAM void shadow()
{
  current_prd_shadow.inShadow = true;

  rtTerminateRay();
}


__device__ float hash(float _seed)
{
    return fract(sin(_seed) * 43758.5453 );
}

//https://www.shadertoy.com/view/MsdGzl
__device__ float3 cosineDirection(float _seed, float3 _n)
{
    // compute basis from normal
    // see http://orbit.dtu.dk/fedora/objects/orbit:113874/datastreams/file_75b66578-222e-4c7d-abdf-f7e255100209/content


    float3 tc = make_float3( 1.0f + _n.z - (_n.x*_n.x),
                             1.0f + _n.z - (_n.y*_n.y),
                             -_n.x * _n.y);
    tc = tc / (1.0f + _n.z);
    float3 uu = make_float3( tc.x, tc.z, -_n.x );
    float3 vv = make_float3( tc.z, tc.y, -_n.y );

    float u = hash( 78.233 + _seed);
    float v = hash( 10.873 + _seed);
    float a = 6.283185 * v;

    return sqrt(u) * (cos(a) * uu + sin(a) * vv) + sqrt(1.0 - u) * _n;
}


rtDeclareVariable(float3,        diffuse_color, , );

typedef rtCallableProgramX<float3()> callT;
rtDeclareVariable(callT, do_work,,);

RT_PROGRAM void diffuse()
{
  float3 world_shading_normal   = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, shading_normal ) );
  float3 world_geometric_normal = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, geometric_normal ) );

  float3 ffnormal = faceforward( world_shading_normal, -ray.direction, world_geometric_normal );

  float3 hitpoint = ray.origin + ( t_hit * ray.direction);

  float z1 = rnd(current_prd.seed);
  float z2 = rnd(current_prd.seed);
  float3 p;

  cosine_sample_hemisphere(z1, z2, p);

  float3 v1, v2;
  createONB(ffnormal, v1, v2);

//  current_prd.direction = v1 * p.x + v2 * p.y + ffnormal * p.z;
  current_prd.direction = cosineDirection(current_prd.seed/* + frame_number*/, world_geometric_normal);
  current_prd.attenuation = /*current_prd.attenuation * */diffuse_color; // use the diffuse_color as the diffuse response
  current_prd.countEmitted = false;

  float3 normal_color = (normalize(world_shading_normal)*0.5f + 0.5f)*0.9;

  // @Todo, trace back from the hit to calculate a new sample point?
//  PerRayData_pathtrace backwards_prd;
//  backwards_prd.origin = hitpoint;
//  backwards_prd.direction = -ray.direction;

  // Compute direct light...
  // Or shoot one...
  unsigned int num_lights = lights.size();
  float3 result = make_float3(0.0f);

  for(int i = 0; i < num_lights; ++i)
  {
    ParallelogramLight light = lights[i];

    // Sample random point on geo light
    float z1 = rnd(current_prd.seed);
    float z2 = rnd(current_prd.seed);
    float3 light_pos = light.corner + light.v1 * z1 + light.v2 * z2;
//    light_pos = make_float3(0, 1000, 0);

//    hitpoint = rtTransformPoint(RT_OBJECT_TO_WORLD, hitpoint);

    float Ldist = length(light_pos - hitpoint);
    float3 L = normalize(light_pos - hitpoint);
    float nDl = dot( shading_normal, L );
    float LnDl = dot( light.normal, L );
    float A = length(cross(light.v1, light.v2));

    // cast shadow ray
    if ( nDl > 0.0f && LnDl > 0.0f )
    {
      PerRayData_pathtrace_shadow shadow_prd;
      shadow_prd.inShadow = false;
      shadow_prd.depth = 0;
      shadow_prd.attenuation = 1.0f;

      Ray shadow_ray = make_Ray(hitpoint + (shading_normal * 0.01), L, pathtrace_shadow_ray_type, scene_epsilon, Ldist );
      rtTrace(top_shadower, shadow_ray, shadow_prd);

      if(!shadow_prd.inShadow)
      {
        float weight= nDl * LnDl * A / (M_PIf*Ldist*Ldist);
        result += light.emission * weight;
      }

    }
  }

  float3 colourtrap = make_float3(iterations / float(max_iterations) );
//  colourtrap = make_float3(smallestdistance) * 1.0f;

  float3 a = make_float3(0.4f, 0.2f, 0.2f);
  float3 b = make_float3(0.5f, 0.5f, 0.55f);
//  colourtrap = lerp(a, b, powf(smallestdistance, 1.0f) );

  float3 ambient = make_float3(0.1f);

  current_prd.result = make_float4(result/* * colourtrap*//* + ambient*/, 1.0);
//  current_prd.result = make_float4( do_work(), 1.0f );
  current_prd.result_nrm = shading_normal;
  current_prd.result_world = hitpoint;
  current_prd.result_depth = t_hit;
  current_prd.done = true;
}

//-----------------------------------------------------------------------------
//
//  Miss program
//
//-----------------------------------------------------------------------------
RT_PROGRAM void miss(){
    current_prd.result = make_float4(0.0, 0.0, 0.0f, 0.0f);
    current_prd.result_nrm = make_float3(0.0, 0.0, 0.0);
    current_prd.result_world = make_float3(0.0, 0.0, 0.0);
    current_prd.result_depth = RT_DEFAULT_MAX;

    current_prd.done = true;
}

//
// Chrome shader for force particle.
//

RT_PROGRAM void chrome_ah_shadow()
{
//  // this material is opaque, so it fully attenuates all shadow rays
  prd_radiance.attenuation = make_float3(0);
//  rtTerminateRay();
}

rtTextureSampler<float4, 2> envmap;
RT_PROGRAM void envmap_miss()
{
  float theta = atan2f( ray.direction.x, ray.direction.z );
  float phi   = M_PIf * 0.5f -  acosf( ray.direction.y );
  float u     = (theta + M_PIf) * (0.5f * M_1_PIf);
  float v     = 0.5f * ( 1.0f + sin(phi) );
//  prd_radiance.result = make_float3( tex2D(envmap, u, v) );

  current_prd.done = true;
  current_prd.result = tex2D(envmap, u, v);
  current_prd.result.w = 0.0; // Alpha should be 0 if we missed
  current_prd.result_nrm = make_float3(0.0, 0.0, 0.0);
  current_prd.result_world = make_float3(0.0, 0.0, 0.0);
  current_prd.result_depth = RT_DEFAULT_MAX;
  rtTerminateRay();
}
