#ifndef ATMOSPHERE_HLSL
#define ATMOSPHERE_HLSL



cbuffer CBAtmosphereParameter : register(b5)
{
    int g_RenderTargetWidth;
    int g_RenderTargetHeight;
    float g_Time;
    float3 g_CameraLookAt; // from camera
    float3 g_LightDir; // from sun
    float3 g_CameraRight;
    float2 g_Padding;
}

Texture2D<float> g_DepthTexture : register(t6);
Texture2D<float4> g_LitTexture : register(t7);
SamplerState g_Sampler : register(s0);


struct VertexPosNormalTex
{
    float3 posL : POSITION;
    float3 normalL : NORMAL;
    float2 texCoord : TEXCOORD;
};

struct AtmosphereVSOut
{
    float4 posViewport : SV_Position;
    float2 texCoord : texCoord;
};

AtmosphereVSOut AtmosphereVS(VertexPosNormalTex input)
{
    AtmosphereVSOut output;
    
    output.posViewport = float4(input.posL.x, input.posL.z, input.posL.y, 1.0f); // set x,y -> [-1, 1]
    output.texCoord = input.texCoord; // origin at top left
    
    return output;
}



// first, lets define some constants to use (planet radius, position, and scattering coefficients)
#define PLANET_POS float3(0.0, 0.0, 0.0) /* the position of the planet */
#define PLANET_RADIUS 6371e3 /* radius of the planet */
#define ATMOS_RADIUS 6471e3 /* radius of the atmosphere */
// scattering coeffs
#define RAY_BETA float3(5.5e-6, 13.0e-6, 22.4e-6) /* rayleigh, affects the color of the sky */
#define MIE_BETA float3(21e-6, 21e-6, 21e-6) /* mie, affects the color of the blob around the sun */
#define AMBIENT_BETA float3(0.0, 0.0, 0.0) /* ambient, affects the scattering color when there is no lighting from the sun */
#define ABSORPTION_BETA float3(2.04e-5, 4.97e-5, 1.95e-6) /* what color gets absorbed by the atmosphere (Due to things like ozone) */
#define G 0.7 /* mie scattering direction, or how big the blob around the sun is */
// and the heights (how far to go up before the scattering has no effect)
#define HEIGHT_RAY 8e3 /* rayleigh height */
#define HEIGHT_MIE 1.2e3 /* and mie */
#define HEIGHT_ABSORPTION 30e3 /* at what height the absorption is at it's maximum */
#define ABSORPTION_FALLOFF 4e3 /* how much the absorption decreases the further away it gets from the maximum height */
// and the steps (more looks better, but is slower)
// the primary step has the most effect on looks
//#if HW_PERFORMANCE==0
//// edit these if you are on mobile
//#define PRIMARY_STEPS 12 
//#define LIGHT_STEPS 4
//# else
// and these on desktop
#define PRIMARY_STEPS 32 /* primary steps, affects quality the most */
#define LIGHT_STEPS 8 /* light steps, how much steps in the light direction are taken */
//#endif

/*
Next we'll define the main scattering function.
This traces a ray from start to end and takes a certain amount of samples along this ray, in order to calculate the color.
For every sample, we'll also trace a ray in the direction of the light, 
because the color that reaches the sample also changes due to scattering
*/
float3 calculate_scattering(
	float3 start, // the start of the ray (the camera position)
    float3 dir, // the direction of the ray (the camera vector) start from camera
    float max_dist, // the maximum distance the ray can travel (because something is in the way, like an object)
    float3 scene_color, // the color of the scene
    float3 light_dir, // the direction of the light, start from sun
    float3 light_intensity, // how bright the light is, affects the brightness of the atmosphere
    float3 planet_position, // the position of the planet
    float planet_radius, // the radius of the planet
    float atmo_radius, // the radius of the atmosphere
    float3 beta_ray, // the amount rayleigh scattering scatters the colors (for earth: causes the blue atmosphere)
    float3 beta_mie, // the amount mie scattering scatters colors
    float3 beta_absorption, // how much air is absorbed
    float3 beta_ambient, // the amount of scattering that always occurs, cna help make the back side of the atmosphere a bit brighter
    float g, // the direction mie scatters the light in (like a cone). closer to -1 means more towards a single direction
    float height_ray, // how high do you have to go before there is no rayleigh scattering?
    float height_mie, // the same, but for mie
    float height_absorption, // the height at which the most absorption happens
    float absorption_falloff, // how fast the absorption falls off from the absorption height
    int steps_i, // the amount of steps along the 'primary' ray, more looks better but slower
    int steps_l // the amount of steps along the light ray, more looks better but slower
)
{
    // add an offset to the camera position, so that the atmosphere is in the correct position
    start -= planet_position;
    // calculate the start and end position of the ray, as a distance along the ray
    // we do this with a ray sphere intersect
    float a = dot(dir, dir);
    float b = 2.0 * dot(dir, start);
    float c = dot(start, start) - (atmo_radius * atmo_radius);
    float d = (b * b) - 4.0 * a * c;
    
    // stop early if there is no intersect
    if (d < 0.0)
        return scene_color;
    
    // calculate the ray length
    float2 ray_length = float2(
        max((-b - sqrt(d)) / (2.0 * a), 0.0),
        min((-b + sqrt(d)) / (2.0 * a), max_dist)
    );
    
    // if the ray did not hit the atmosphere, return a black color
    if (ray_length.x > ray_length.y)
        return scene_color;
    // prevent the mie glow from appearing if there's an object in front of the camera
    bool allow_mie = max_dist > ray_length.y;
    // make sure the ray is no longer than allowed
    ray_length.y = min(ray_length.y, max_dist);
    ray_length.x = max(ray_length.x, 0.0);
    // get the step size of the ray
    float step_size_i = (ray_length.y - ray_length.x) / float(steps_i);
    
    // next, set how far we are along the ray, so we can calculate the position of the sample
    // if the camera is outside the atmosphere, the ray should start at the edge of the atmosphere
    // if it's inside, it should start at the position of the camera
    // the min statement makes sure of that
    float ray_pos_i = ray_length.x + step_size_i * 0.5;
    
    // these are the values we use to gather all the scattered light
    float3 total_ray = float3(0.0, 0.0, 0.0); // for rayleigh
    float3 total_mie = float3(0.0, 0.0, 0.0); // for mie
    
    // initialize the optical depth. This is used to calculate how much air was in the ray
    float3 opt_i = float3(0.0, 0.0, 0.0);
    
    // also init the scale height, avoids some vec2's later on
    float2 scale_height = float2(height_ray, height_mie);
    
    // Calculate the Rayleigh and Mie phases.
    // This is the color that will be scattered for this ray
    // mu, mumu and gg are used quite a lot in the calculation, so to speed it up, precalculate them
    float mu = dot(dir, light_dir);
    float mumu = mu * mu;
    float gg = g * g;
    float phase_ray = 3.0 / (50.2654824574 /* (16 * pi) */) * (1.0 + mumu); // cdh: 相位函数
    float phase_mie = allow_mie ? 3.0 / (25.1327412287 /* (8 * pi) */) * ((1.0 - gg) * (mumu + 1.0)) / (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg)) : 0.0;
    
    // now we need to sample the 'primary' ray. this ray gathers the light that gets scattered onto it
    for (int i = 0; i < steps_i; ++i)
    {
        
        // calculate where we are along this ray
        float3 pos_i = start + dir * ray_pos_i;
        
        // and how high we are above the surface
        float height_i = length(pos_i) - planet_radius;
        
        // now calculate the density of the particles (both for rayleigh and mie) //cdh: 光学深度, x:rayleigh, y:mie, z:ozone
        float3 density = float3(exp(-height_i / scale_height), 0.0);
        
        // and the absorption density. this is for ozone, which scales together with the rayleigh, 
        // but absorbs the most at a specific height, so use the sech function for a nice curve falloff for this height
        // clamp it to avoid it going out of bounds. This prevents weird black spheres on the night side
        float denom = (height_absorption - height_i) / absorption_falloff;
        density.z = (1.0 / (denom * denom + 1.0)) * density.x;
        
        // multiply it by the step size here
        // we are going to use the density later on as well
        density *= step_size_i;
        
        // Add these densities to the optical depth, so that we know how many particles are on this ray.
        opt_i += density; //cdh: 光学深度, x:rayleigh, y:mie, z:ozone
        
        // Calculate the step size of the light ray.
        // again with a ray sphere intersect
        // a, b, c and d are already defined
        a = dot(light_dir, light_dir);
        b = 2.0 * dot(light_dir, pos_i);
        c = dot(pos_i, pos_i) - (atmo_radius * atmo_radius);
        d = (b * b) - 4.0 * a * c;

        // no early stopping, this one should always be inside the atmosphere
        // calculate the ray length
        float step_size_l = (-b + sqrt(d)) / (2.0 * a * float(steps_l));

        // and the position along this ray
        // this time we are sure the ray is in the atmosphere, so set it to 0
        float ray_pos_l = step_size_l * 0.5;

        // and the optical depth of this ray
        float3 opt_l = float3(0.0, 0.0, 0.0);
            
        // now sample the light ray
        // this is similar to what we did before
        for (int l = 0; l < steps_l; ++l)
        {

            // calculate where we are along this ray
            float3 pos_l = pos_i + light_dir * ray_pos_l;

            // the heigth of the position
            float height_l = length(pos_l) - planet_radius;

            // calculate the particle density, and add it
            // this is a bit verbose
            // first, set the density for ray and mie
            float3 density_l = float3(exp(-height_l / scale_height), 0.0);
            
            // then, the absorption
            float denom = (height_absorption - height_l) / absorption_falloff;
            density_l.z = (1.0 / (denom * denom + 1.0)) * density_l.x;
            
            // multiply the density by the step size
            density_l *= step_size_l;
            
            // and add it to the total optical depth
            opt_l += density_l;
            
            // and increment where we are along the light ray.
            ray_pos_l += step_size_l;
            
        }
        
        // Now we need to calculate the attenuation
        // this is essentially how much light reaches the current sample point due to scattering
        float3 attn = exp(-beta_ray * (opt_i.x + opt_l.x) - beta_mie * (opt_i.y + opt_l.y) - beta_absorption * (opt_i.z + opt_l.z));

        // accumulate the scattered light (how much will be scattered towards the camera)
        total_ray += density.x * attn;
        total_mie += density.y * attn;

        // and increment the position on this ray
        ray_pos_i += step_size_i;
    	
    }
    
    // calculate how much light can pass through the atmosphere
    float3 opacity = exp(-(beta_mie * opt_i.y + beta_ray * opt_i.x + beta_absorption * opt_i.z));
    
	// calculate and return the final color
    return (
        	phase_ray * beta_ray * total_ray // rayleigh color
       		+ phase_mie * beta_mie * total_mie // mie
            + opt_i.x * beta_ambient // and ambient
    ) * light_intensity + scene_color * opacity; // now make sure the background is rendered correctly
}

/*
next, we need a way to do something with the scattering function

to do something with it we need the camera vector (which is the ray direction) of the current pixel
this function calculates it
*/
float3 get_camera_vector(float2 uv, float3 camera_look_at, float3 camera_right)
{
    uv -= float2(0.5, 0.5);
    uv.x *= g_RenderTargetWidth / (float)g_RenderTargetHeight;
    
    camera_right = normalize(camera_right);
    float3 camera_up = normalize(cross(camera_right, camera_look_at));

    return normalize(camera_look_at + uv.x * camera_right + uv.y * camera_up);
}

float4 AtmospherePS(AtmosphereVSOut input) : SV_Target
{
    float depth = g_DepthTexture.Sample(g_Sampler, input.texCoord);
    
    if(depth < 1.0f)
    {
        float3 color = g_LitTexture.Sample(g_Sampler, input.texCoord).rgb;
        return float4(color, 0.0f);
    }
    else
    {
        float2 uv = input.texCoord * float2(1.0f, -1.0f) + float2(0.0f, 1.0f); // reverse y axis, let the origin point be left-bottom side in screen space;
    
        // get the camera vector
        float3 camera_vector = get_camera_vector(uv, g_CameraLookAt * float3(1, 1, -1), g_CameraRight * float3(1, 1, -1)); // start from camera
        float3 camera_position = float3(0.0, PLANET_RADIUS + 200.0, 0.0);
        float3 light_dir = normalize(-g_LightDir * float3(1, 1, -1)); //normalize(float3(0.0f, cos(-g_Time / 3), sin(-g_Time / 3))); // start from sun
        float3 background = float3(0.0f, 0.0f, 0.0f);
    
        float3 color = float3(0.0f, 0.0f, 0.0f);
    
        // get the atmosphere color
        color += calculate_scattering(
        camera_position, // the position of the camera
        camera_vector, // the camera vector (ray direction of this pixel)
        10000000, // max dist, essentially the scene depth
        background, // scene color, the color of the current pixel being rendered //cdh: background color
        light_dir, // light direction
        float3(40.0, 40.0, 40.0), // light intensity, 40 looks nice
        PLANET_POS, // position of the planet
        PLANET_RADIUS, // radius of the planet in meters
        ATMOS_RADIUS, // radius of the atmosphere in meters
        RAY_BETA, // Rayleigh scattering coefficient
        MIE_BETA, // Mie scattering coefficient
        ABSORPTION_BETA, // Absorbtion coefficient
        AMBIENT_BETA, // ambient scattering, turned off for now. This causes the air to glow a bit when no light reaches it
        G, // Mie preferred scattering direction
        HEIGHT_RAY, // Rayleigh scale height
        HEIGHT_MIE, // Mie scale height
        HEIGHT_ABSORPTION, // the height at which the most absorption happens
        ABSORPTION_FALLOFF, // how fast the absorption falls off from the absorption height 
        PRIMARY_STEPS, // steps in the ray direction 
        LIGHT_STEPS // steps in the light direction
        );
    
        // apply exposure, removing this makes the brighter colors look ugly
        // you can play around with removing this
        color = 1.0 - exp(-0.5 * color);

        return float4(color, 0.0f);
    }
    
    
    
}


#endif