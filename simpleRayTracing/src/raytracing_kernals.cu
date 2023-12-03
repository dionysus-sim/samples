#include "raytracing_kernals.h"
#include "materials\Material.cuh"

__forceinline __device__ float3 rayEnvironmentIntersection(Trace::Ray& ray, Trace::Environment* env, curandState* rand) {

    int nBounces = 3;
    float3 attenuation = make_float3(1.0f, 1.0f, 1.0f);
    float3 background = make_float3(0.5f, 0.7f, 1.0f);

    for (int k = 0; k < nBounces; k++) {

        // Ray environment intersection test
        Trace::Record hit;
        if (!(env->hit(ray, hit))) {
            return attenuation * background;
        }

        // Material effect
        Trace::Material mat = env->materials[hit.matID];
        if (mat.emitted(ray, hit)) { 
            return attenuation * ray.albedo; 
        }
        mat.scatter(ray, hit, rand);

        // Attenuate light
        attenuation *= ray.albedo;

        attenuation.x = fmaxf(attenuation.x, 0.0f);
        attenuation.y = fmaxf(attenuation.y, 0.0f);
        attenuation.z = fmaxf(attenuation.z, 0.0f);
        attenuation.x = fminf(attenuation.x, 1.0f);
        attenuation.y = fminf(attenuation.y, 1.0f);
        attenuation.z = fminf(attenuation.z, 1.0f);

    }

    return attenuation;
}

__global__ void Trace::execute_k(
    float3* pixelBuffer, 
    int width, 
    int height, 
    int nSamples, 
    Trace::Environment* env, 
    Trace::Camera camera, 
    curandState* rand)
{
    // Get thread information
    const int px = threadIdx.x + blockIdx.x * blockDim.x;
    const int py = threadIdx.y + blockIdx.y * blockDim.y;
    const int pIdx = py * width + px;


    if (px < width && py < height) {

        // Initialize random number generator
        curandState randN = rand[pIdx];

        // Sample pixel color
        float3 pixelColor = make_float3(0.0f);
        for (int j = 0; j < nSamples; j++) {

            // Pixel position
            float u = ((float) px - (curand_uniform(&randN) - 0.5f)) / (float) width;
            float v = ((float) py - (curand_uniform(&randN) - 0.5f)) / (float) height;

            // Project ray
            Trace::Ray ray(camera.position, camera.getPixelPosition(u, v));
            pixelColor += rayEnvironmentIntersection(ray, env, &randN);

            // Sync threads to limit the number of active warps
            __syncwarp();
            //__syncthreads();
        }
        pixelColor /= (float) nSamples;

        pixelBuffer[pIdx].x = sqrtf(pixelColor.x);
        pixelBuffer[pIdx].y = sqrtf(pixelColor.y);
        pixelBuffer[pIdx].z = sqrtf(pixelColor.z);
    }
}

extern "C" void Trace::execute(const Trace::Pipeline& pipeline, float3* pixelBuffer) {

    int txy = 16;
    dim3 B = dim3(pipeline.imageWidth / txy + 1, pipeline.imageHeight / txy + 1);
    dim3 T = dim3(txy, txy, 1);

    execute_k<<<B,T>>>(
        pixelBuffer,
        pipeline.imageWidth,
        pipeline.imageHeight,
        pipeline.nSamples,
        pipeline.d_environment,
        pipeline.camera,
        pipeline.d_rand);
}

__global__ void Trace::initRandomState_k(curandState* rand, int width, int height, int SEED_CONSTANT) {

    const int px = threadIdx.x + blockIdx.x * blockDim.x;
    const int py = threadIdx.y + blockIdx.y * blockDim.y;
    const int pIdx = py * width + px;

    if ((px < width) && (py < height)) {

        // Initialize random number generator
        curand_init(pIdx + px + SEED_CONSTANT, px + py * width, blockIdx.x * blockDim.x, &rand[pIdx]);
    }
}

extern "C" void Trace::initRandomState(Trace::Pipeline& pipeline, int SEED_CONSTANT) {

    int txy = 16;
    dim3 B = dim3(pipeline.imageWidth / txy + 1, pipeline.imageHeight / txy + 1);
    dim3 T = dim3(txy, txy, 1);


    cudaMalloc((void**) &pipeline.d_rand, pipeline.imageWidth * pipeline.imageHeight * sizeof(curandState));
    initRandomState_k<<<B,T>>>(pipeline.d_rand, pipeline.imageWidth, pipeline.imageHeight, SEED_CONSTANT);

}
