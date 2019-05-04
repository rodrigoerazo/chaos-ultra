#include <cuda_runtime_api.h>
#include <math.h>
#include <float.h>
#include "helpers.hpp"
#include "fractal.cuh"

typedef unsigned int uint;
using Pointf = Point<float>;
using Pointi = Point<uint>;

__device__ const float PI_F = 3.14159265358979f;
__device__ const uint MAX_SS_LEVEL = 256;


extern "C" __global__
void init(){

}

/// Dispersion in this context is "Index of dispersion", aka variance-to-mean ratio. See https://en.wikipedia.org/wiki/Index_of_dispersion for more details
template <class Real> __device__ __forceinline__
Real computeDispersion(uint* data, uint dataLength, Real mean){
  uint n = dataLength;
  Real variance = 0;
  for(uint i = 0; i < dataLength; i++){
    //using numerically stable Two-Pass algorithm, https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Two-pass_algorithm
    variance += (data[i]-mean)*(data[i]-mean);
  }
  variance /= (n-1); 
  return variance / mean;
}


__device__ __forceinline__
bool isWithinRadius(uint idx_x, uint idx_y, uint width, uint height, uint radius, uint focus_x, uint focus_y){
  if(__sad(idx_x, focus_x, 0) > radius / 2) return false;
  if(__sad(idx_y, focus_y, 0) > radius / 2) return false;
  else return true;

  // if(idx_x < (width - radius)/2 || idx_y < (height-radius)/2) return false;
  // if(idx_x > (width + radius)/2 || idx_y > (height+radius)/2) return false;
  // else return true;
}

__device__ long seed;
/// Intended for debugging only
__device__ __forceinline__ uint simpleRandom(uint val){
    long long a = 1103515245;
    long long c = 12345;
    long long m = 4294967295l; //2**32 - 1
    seed = (a * (val+seed) + c) % m;
    return seed;
}

__device__ const uint WARP_SIZE_X = 8; //represents desired size of the recatangular warp (with respect to threadIdx). WARP_SIZE.x * WARP_SIZE.y should always be warpSize (32 for CUDA 9 and lower)
__device__ const uint WARP_SIZE_Y = 4;
  /// Computes indexes to a per-pixel acces of a 2D image, based on threadIdx and blockIdx.
  /// Morover, threads in a warp will be arranged in a rectangle (rather than in single line as with the naive implementation).
  /// The caller should always check if the returned value exceeded image width and height.
__device__ const Point<uint> getImageIndexes(){
  const uint threadID = threadIdx.x + threadIdx.y * blockDim.x;
  const uint warpH = WARP_SIZE_Y; // 2,4,8 are only reasonable values of warpH for the following formula
  const uint blockWidth = blockDim.x * warpH;
  ASSERT (blockDim.x == 32); //following formula works only when blockDim.x is 32 
  const uint inblock_idx_x = (-(threadID % (warpH * warpH)) + threadID % blockWidth) / warpH + threadID % warpH;
  const uint inblock_idx_y = (threadID / blockWidth) * warpH + (threadID / warpH) % warpH;
  const uint idx_x = blockDim.x * blockIdx.x + inblock_idx_x;
  const uint idx_y = blockDim.y * blockIdx.y + inblock_idx_y;

  // does this fix the right bottom corner problem?
  // idx_x = blockIdx.x * blockDim.x + threadIdx.x;
  // idx_y = blockIdx.y * blockDim.y + threadIdx.y;

  // { //debug
  //   uint warpid = threadID / warpH;
  //   if(idx_x < 20 && idx_y < 20){
  //     //printf("bw:%u\n", blockWidth);
  //     printf("%u\t%u\t%u\t%u\t%u\n", threadIdx.x, threadIdx.y, threadID ,inblock_idx_x, inblock_idx_y);
  //   }
  // }
  return Point<uint>(idx_x, idx_y);
}

__device__ __forceinline__
pixel_info_t* getPtrToPixel(pixel_info_t** array2D, long pitch, uint x, uint y){
  return (((pixel_info_t*)((char*)array2D + y * pitch)) + x);
}

__device__ __forceinline__
uint colorizeSampleCount(uint sampleCount){
  const uint sampleCount100Percent = 25;
  sampleCount = min(sampleCount, sampleCount100Percent);
  float sampleCountRel = sampleCount / (float) sampleCount100Percent;
  uint gray = (uint) (255 * sampleCountRel);
  return 0xff000000 + gray + (gray << 2) + (gray << 4);
}

/// param sampleCount: Maximum number of samples to take. Actual number of samples taken will be stored here before returning. If adaptiveSS==false, the value will not change.
template <class Real> __device__
uint sampleTheFractal(Pointi pixel, Pointi size, Rectangle<Real> image, uint maxIterations,uint & sampleCount, bool adaptiveSS){
  const uint adaptiveTreshold = 10;
  uint r[adaptiveTreshold];

  //We are in a complex plane from (left_bottom) to (right_top), so we scale the pixels to it
  Point<Real> pixelSize = image.size() / size.cast<Real>();
  
  uint escapeTimeSum = 0;
  ASSERT (sampleCount <= MAX_SS_LEVEL);
  for(uint i = 0; i < sampleCount; i++){
    Point<Real> delta = Point<Real>(i / (Real) sampleCount);
    
    // c = {LBx, RTy} {+,-} ((pixel+delta) * pixelSize)
    const Point<Real> c = Point<Real>(image.left_bottom.x, image.right_top.y) +
      Point<Real>(1,-1) * (pixel.cast<Real>() + delta) * pixelSize;

    uint escapeTime = iterate(maxIterations, c);
    escapeTimeSum += escapeTime;
    if(i < adaptiveTreshold){
      r[i] = escapeTime;
    }

    //todo this process should ideally adaptive, at least dynamic. Not predefined like.
    if(( i== 2 || i == adaptiveTreshold) && adaptiveSS){ //decide whether to continue with supersampling or not
      Real mean = escapeTimeSum / (i+1);
      Real dispersion = computeDispersion(r, i, mean);
      float dispersionMax = (i==2) ? 0.01 : 0.1;
      if(__ALL(dispersion <= dispersionMax )){
        sampleCount = i+1; //effectively disabling high SS and storing info about actual number of samples taken
      }
      //else we are on an chaotic edge, thus as many samples as possible are needed
    }
  }
  uint result = escapeTimeSum / sampleCount; 
  return result;
   

  //debug:
  // if(idx_x < 10 && idx_y < 10){
  //   printf("%f\t", randomSample);
  //   __syncthreads();
  //   if(idx_x == 0 && idx_y == 0)
  //     printf("\n");
  // }
} 

__device__ const uint USE_ADAPTIVE_SS_FLAG_MASK = (1 << 0);
__device__ const uint VISUALISE_SAMPLE_COUNT_FLAG_MASK = (1 << 1);
__device__ const uint USE_FOVEATION_FLAG_MASK = (1 << 2);
__device__ const uint USE_SAMPLE_REUSE_FLAG_MASK = (1 << 3);
__device__ const uint IS_ZOOMING_FLAG_MASK = (1 << 4);

__device__ const uint visualityAmplifyCoeff = 10;

template <class Real> __device__ __forceinline__
void fractalRenderMain(pixel_info_t** output, long outputPitch, Pointi outputSize, Rectangle<Real> image, uint maxIterations, uint maxSuperSampling, uint flags)
{
  const Pointi idx = getImageIndexes();
  if(idx.x >= outputSize.x || idx.y >= outputSize.y) return;
  if(idx.x == 0 && idx.y == 0){
    // printf("fractal render main\n");
    // printf("image:\t%f\t%f\t%f\t%f\n", image.left_bottom.x, image.left_bottom.y, image.right_top.x, image.right_top.y);
    // printf("outputsize:\t%d\t%d\n", outputSize.x, outputSize.y);
    // printf("focus:\t%d\t%d\n", focus.x, focus.y);
    // printf("dwell:\t%d\tss:\t%d\n", maxIterations, maxSuperSampling);
    // printf("\n");
  }
  
  //the value of maxSuperSampling will be changed by the calee
  uint result = sampleTheFractal(idx, outputSize, image, maxIterations, maxSuperSampling, flags & USE_ADAPTIVE_SS_FLAG_MASK);

  if(flags & VISUALISE_SAMPLE_COUNT_FLAG_MASK){
    result = maxSuperSampling * visualityAmplifyCoeff;
  }

  pixel_info_t* pOutput = getPtrToPixel(output, outputPitch, idx.x, idx.y);
  pOutput->value = result;
  pOutput->weight = (float) maxSuperSampling;
  ASSERT(pOutput->weight > 0);
}

/// for given point <code>p</code> in the current image and given warping information, find cooridnates of the same point (=representing the same point in the fractal's complex plane) in the image being warped
/// @param p: the point whose warping origin is being returned
/// @param imageSize: width and height (in pixels) of current image
/// @param currentImage: rectangle representing the part of the complex plane that is being rendered
/// @param oldImage: rectangle representing the part of the complex plane that is being reused

template <class Real> __device__ __forceinline__
Point<Real> getWarpingOrigin(Point<Real> p, Point<Real> imageSize, Rectangle<Real> currentImage, Rectangle<Real> oldImage){

      Point<Real> size_current = currentImage.size();
      Point<Real> size_reused = oldImage.size();
      Point<Real> coeff = size_current / size_reused;

      Point<Real> deltaReal;    
      deltaReal.x = currentImage.left_bottom.x - oldImage.left_bottom.x;
      deltaReal.y = oldImage.right_top.y - currentImage.right_top.y;
      Point<Real> delta = deltaReal / size_current * imageSize;

      Point<Real> result = (p * coeff) + delta;
      return result;
}

__device__ float screenDistance = 60; //in cm; better be set by the user
__device__ __forceinline__
/// Returns how many samples this pixel should take, based on foveation.
/// Value is between 0 and maxSuperSamplingLevel.
/// Value in the focus will always be maxSuperSamplingLevel, values in the non-peripheral view will always be non-zero.
/// Returned value is the same for all pixels within a warp (the highest is taken).
uint getAdvisedSampleCount(Pointi pixel, Pointi focus, uint maxSuperSamplingLevel){
  //per-warp normalisation, i.e. set all pixels from a warp to same value
  pixel = pixel - (pixel % Pointi(WARP_SIZE_X, WARP_SIZE_Y));

  float pixelRealWidthInCm = 0.02652; //todo this value should probably be entered by the user. From http://www.prismo.ch/comparisons/desktop.php 
  float focusDistance = focus.cast<float>().distanceTo(pixel.cast<float>()) * pixelRealWidthInCm; //distance to focus, translated to cm
  /// visual angle for one eye, i.e possible values are from 0 to ~ 110
  float visualAngle = atan (focusDistance / screenDistance) * 180 / PI_F; //from https://en.wikipedia.org/wiki/Visual_angle
  
  //used model for (visualAngle -> relativeQuality): in (0,fovealViewLimit): a constant function that yields 1, in (fovealViewLimit, peripheralViewLimit): descenidng linear function from 1 to 0
  ASSERT(visualAngle >= 0); //arctan is positive for positive input and distance is always non-negative
  const float fovealViewLimit = 5.5; //in degrees, value from https://en.wikipedia.org/wiki/Peripheral_vision
  ///todo, this number is based on a paper. Based on my experience, it could be even smaller
  const float peripheralViewTreshold = 60;  //in degrees, value from https://en.wikipedia.org/wiki/Peripheral_vision
  float relativeQuality = (1/(fovealViewLimit-peripheralViewTreshold))*visualAngle+(-peripheralViewTreshold/(fovealViewLimit-peripheralViewTreshold)); 
  if(visualAngle <= fovealViewLimit) relativeQuality = 1;

  uint result = maxSuperSamplingLevel * relativeQuality;
  if(visualAngle <= peripheralViewTreshold)
    result = max(1, result); //always return at least 1 for pixels within the field of view
  return result;
}

template <class Real> __device__ 
void fractalRenderAdvanced(pixel_info_t** output, long outputPitch, Pointi outputSize, Rectangle<Real> image, uint maxIterations, uint maxSuperSampling, uint flags, Rectangle<Real> imageReused, pixel_info_t** input, long inputPitch, Pointi focus){

  const Pointi idx = getImageIndexes();
  if(idx.x >= outputSize.x || idx.y >= outputSize.y) return;
  if(idx.x == 0 && idx.y == 0){
    // printf("fractalRenderAdvanced:\n");
    // printf("\t maxIterations:%d\n",maxIterations);
    // printf("\t focus:%d,%d\n",focus.x, focus.y);
    // printf("\t fov:%d\n",(flags & USE_FOVEATION_FLAG_MASK));
    // printf("\t reuse:%d\n",flags & USE_SAMPLE_REUSE_FLAG_MASK);
    // printf("\t ad SS:%d\n",flags & USE_ADAPTIVE_SS_FLAG_MASK);
    // printf("\t zooming:%d\n",flags & IS_ZOOMING_FLAG_MASK);
    // printf("\n");
  }
  ASSERT(idx.x < outputSize.x);
  ASSERT(idx.y < outputSize.y);

  //sample reusal:
  bool reusingSample = false;
  uint reusalResult;
  float reusalWeight;
  if(flags & USE_SAMPLE_REUSE_FLAG_MASK){
    const Point<Real> originr = getWarpingOrigin(Point<Real>(idx.x, idx.y),outputSize.cast<Real>(),image, imageReused);
    const Point<int> origin = Point<int>((int)round(originr.x), (int)round(originr.y)); //it is important to convert to signed int, not uint (because the value may be negative)
    if(origin.x < 0 || origin.x >= outputSize.x || origin.y < 0 || origin.y >= outputSize.y){
      reusingSample = false;
    }
    else{
      pixel_info_t* pInput = getPtrToPixel(input, inputPitch, origin.x, origin.y);
      reusalResult = pInput->value;
      reusalWeight = (float) pInput->weight;
      reusingSample = true;
    }
  }
  
  //sample generation:
  uint sampleCount = maxSuperSampling;
  if (flags & USE_FOVEATION_FLAG_MASK)
    sampleCount = getAdvisedSampleCount(idx, focus, maxSuperSampling);
  if((!reusingSample || reusalWeight == 0) && sampleCount == 0)  sampleCount = 1; //at least one sample has to be taken somewhere
      //indeed, it may happen that reusalWeight == 0, because reusalWeight decreases in time (see reusedSampleDegradateCoeff)
  uint renderResult = sampleTheFractal(idx, outputSize, image, maxIterations, sampleCount, flags & USE_ADAPTIVE_SS_FLAG_MASK);
  ASSERT(reusingSample || sampleCount > 0);

  //combine reused and generated samples:
  uint result;
  float resultWeight;
  if(reusingSample){
    if(sampleCount == 0){
      result = reusalResult;
      resultWeight = reusalWeight;    
    }else{
      const float reusedSampleDegradateCoeff = 0.6; // must be <=1
      if(flags & IS_ZOOMING_FLAG_MASK)
        reusalWeight *= reusedSampleDegradateCoeff;
      resultWeight = reusalWeight + sampleCount;    
      result = (reusalResult * reusalWeight + renderResult * sampleCount) / (resultWeight);
    }
  }else{
    result = renderResult;
    resultWeight = sampleCount;
  }

// //debug pravy dolni roh:
//       uint qqq = 16;
//   if(idx.x >= width-qqq || idx.y >= height-qqq)      
//       result = maxIterations;

  pixel_info_t* pOutput = getPtrToPixel(output, outputPitch, idx.x, idx.y);
  pOutput->value = result;
  pOutput->weight = resultWeight;
  ASSERT(resultWeight > 0);
}


extern "C" __global__
void fractalRenderMainFloat(pixel_info_t** output, long outputPitch, Pointi outputSize, Rectangle<float> image, uint maxIterations, uint maxSuperSampling, uint flags){
  fractalRenderMain<float>(output, outputPitch, outputSize, image, maxIterations, maxSuperSampling, flags);
}

extern "C" __global__
void fractalRenderMainDouble(pixel_info_t** output, long outputPitch, Pointi outputSize, Rectangle<double> image, uint maxIterations, uint maxSuperSampling, uint flags){
  fractalRenderMain<double>(output, outputPitch, outputSize, image, maxIterations, maxSuperSampling, flags);

}

extern "C" __global__
void fractalRenderAdvancedFloat(pixel_info_t** output, long outputPitch, Pointi outputSize, Rectangle<float> image, uint maxIterations, uint maxSuperSampling, uint flags, Rectangle<float> imageReused, pixel_info_t** input, long inputPitch, Pointi focus){
  fractalRenderAdvanced<float>(output, outputPitch, outputSize, image, maxIterations, maxSuperSampling, flags, imageReused, input, inputPitch, focus);
}

extern "C" __global__
void fractalRenderAdvancedDouble(pixel_info_t** output, long outputPitch, Pointi outputSize, Rectangle<double> image, uint maxIterations, uint maxSuperSampling, uint flags, Rectangle<double> imageReused, pixel_info_t** input, long inputPitch, Pointi focus){
  fractalRenderAdvanced<double>(output, outputPitch, outputSize, image, maxIterations, maxSuperSampling, flags, imageReused, input, inputPitch, focus);

}

extern "C" __global__
void compose(pixel_info_t** inputMain, long inputMainPitch, pixel_info_t** inputBcg, long inputBcgPitch, cudaSurfaceObject_t  surfaceOutput, uint width, uint height, cudaSurfaceObject_t colorPalette, uint paletteLength){
    const uint idx_x = blockDim.x * blockIdx.x + threadIdx.x;
    const uint idx_y = blockDim.y * blockIdx.y + threadIdx.y;
    if(idx_x >= width || idx_y >= height) return;

    pixel_info_t* pResult;
    pResult = getPtrToPixel(inputMain, inputMainPitch, idx_x, idx_y);
    uint result = pResult->value;

    uint resultColor;
    //if(flags & VISUALISE_SAMPLE_COUNT_FLAG_MASK)  //todo tento kernel nema flags
    if(false){ 
      resultColor = colorizeSampleCount(result); //todo pass sample count here
    } else{
      resultColor = colorize(colorPalette, paletteLength, result);
    }
    surf2Dwrite(resultColor, surfaceOutput, idx_x * sizeof(uint), idx_y);
}

extern "C" __global__
void fractalRenderUnderSampled(pixel_info_t** output, long outputPitch, uint width, uint height, float left_bottom_x, float left_bottom_y, float right_top_x, float right_top_y, uint maxIterations, uint underSamplingLevel)
{
  //work only at every Nth pixel:
  const uint idx_x = (blockDim.x * blockIdx.x + threadIdx.x) * underSamplingLevel;
  const uint idx_y = (blockDim.y * blockIdx.y + threadIdx.y) * underSamplingLevel;
  if(idx_x >= width-underSamplingLevel || idx_y >= height-underSamplingLevel) return;
  
  //We are in a complex plane from (left_bottom) to (right_top), so we scale the pixels to it
  float pixelWidth = (right_top_x - left_bottom_x) / (float) width;
  float pixelHeight = (right_top_y - left_bottom_y) / (float) height;
  
  float cx = left_bottom_x + (idx_x)  * pixelWidth;
  float cy = right_top_y - (idx_y) * pixelHeight;

  uint escapeTime = iterate(maxIterations, Pointf(cx, cy));

  for(uint x = 0; x < underSamplingLevel; x++){
    for(uint y = 0; y < underSamplingLevel; y++){
      //surf2Dwrite(resultColor, surfaceOutput, (idx_x + x) * sizeof(unsigned uint), (idx_y+y));
      pixel_info_t* pOutput = getPtrToPixel(output, outputPitch, idx_x+x, idx_y+y);
      pOutput->value = escapeTime;
      pOutput->weight = 1 / (float) underSamplingLevel;
    }
  }

}

extern "C" __global__
void debug(){
  const uint idx_x = blockDim.x * blockIdx.x + threadIdx.x;
  const uint idx_y = blockDim.y * blockIdx.y + threadIdx.y;
  if(idx_x == 0 && idx_y == 0){
    // printf("aa:\t%u\n",a.a);
    debugFractal();
  }
}