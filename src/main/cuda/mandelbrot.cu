#include <cuda_runtime_api.h>
#include "math.h"
#include "point.hpp"

typedef unsigned int uint;
using Pointf = Point2D<float>;
using Point = Point2D<uint>;

const uint MAX_SS_LEVEL = 256;

#define CUDA_CALL(x) do { if((x) != cudaSuccess) { \
  printf("Mandelbrot: Error at %s:%d\n",__FILE__,__LINE__); \
  return EXIT_FAILURE;}} while(0)
  
#define CURAND_CALL(x) do { if((x) != CURAND_STATUS_SUCCESS) { \
  printf("Mandelbrot: Error at %s:%d\n",__FILE__,__LINE__); \
  return EXIT_FAILURE;}} while(0)

#define DEBUG_MODE
#ifdef DEBUG_MODE 
  #define ASSERT(x) assert(x)
#else 
  #define ASSERT(x) do {} while(0)
#endif

#ifndef CUDART_VERSION
  #error CUDART_VERSION Undefined!
#elif (CUDART_VERSION >= 9000) //for cuda 9 and later, use __any_sync(__activemask(), predicate) instead, see Programming guide, B.13 for more details
  #define __ALL(predicate) __all_sync(__activemask(), predicate)
  #define __ANY(predicate) __any_sync(__activemask(), predicate)
#else
  #define __ALL(predicate) __all(predicate)
  #define __ANY(predicate) __any(predicate)
#endif


class ColorsARGB{
public:
  static constexpr const uint BLACK = 0xff000000;
  static constexpr const uint WHITE = 0xffffffff;
  static constexpr const uint PINK  = 0xffb469ff;
  static constexpr const uint YELLOW= 0xff00ffff;
  static constexpr const uint GOLD  = 0xff00d7ff;
}; 

typedef struct color{
  char r;
  char g;
  char b;
  char a;
} color_t;

//Mandelbrot content, using standard mathematical terminology for Mandelbrot set definition, i.e.
//  f_n = f_{n-1}^2 + c
//  f_0 = 0
//  thus iteratively applying: f(z) = z*z * c
//  where z, c are complex numbers, with components denoted as
//    x ... for real part (corresponding to geometric x-axis)
//    y ... for imag part (corresponding to geometric y-axis)

/*
template <class Real> __device__ __forceinline__ uint escape(uint dwell, Pointf c){
  Pointf z(0,0);
  Real zx_new;
  uint i = 0;
  while(i < dwell && z.x*z.x+z.y*z.y < 4){
      zx_new = z.x*z.x-z.y*z.y + c.x;
      z.y = 2*z.x*z.y + c.y; 
      z.x = zx_new;
      ++i;
  }
  return i;
}*/

template <class Real> __device__ __forceinline__ uint escape(uint dwell, Real cx, Real cy){
  Real zx = 0;
  Real zy = 0;
  Real zx_new;
  uint i = 0;
  while(i < dwell && zx*zx+zy*zy < 4){
      zx_new = zx*zx-zy*zy + cx;
      zy = 2*zx*zy + cy; 
      zx = zx_new;
      ++i;
  }
  return i;
}

/// Dispersion in this context is "Index of dispersion", aka variance-to-mean ratio. See https://en.wikipedia.org/wiki/Index_of_dispersion for more details
__device__  __forceinline__ float computeDispersion(uint* data, uint dataLength, float mean){
  uint n = dataLength;
  float variance = 0;
  for(uint i = 0; i < dataLength; i++){
    //using numerically stable Two-Pass algorithm, https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Two-pass_algorithm
    variance += (data[i]-mean)*(data[i]-mean);
  }
  variance /= (n-1); 
  return variance / mean;
}

__device__ void printParams_debug(cudaSurfaceObject_t surfaceOutput, long outputDataPitch_debug, uint width, uint height, float left_bottom_x, float left_bottom_y, float right_top_x, float right_top_y, uint dwell, uint** outputData_debug, cudaSurfaceObject_t colorPalette, uint paletteLength, float* randomSamples, uint superSamplingLevel, bool adaptiveSS, bool visualiseSS){
  const uint idx_x = blockDim.x * blockIdx.x + threadIdx.x;
  const uint idx_y = blockDim.y * blockIdx.y + threadIdx.y;
  if(idx_x != 0 || idx_y != 0)
    return;
  printf("\n");
  printf("width:\t%d\n",width);
  printf("height:\t%d\n",height);
  printf("dwell:\t%d\n",dwell);
  printf("SS lvl:\t%d\n",superSamplingLevel);
}

__device__ __forceinline__ bool isWithinRadius(uint idx_x, uint idx_y, uint width, uint height, uint radius, uint focus_x, uint focus_y){
  if(__sad(idx_x, focus_x, 0) > radius / 2) return false;
  if(__sad(idx_y, focus_y, 0) > radius / 2) return false;
  else return true;

  // if(idx_x < (width - radius)/2 || idx_y < (height-radius)/2) return false;
  // if(idx_x > (width + radius)/2 || idx_y > (height+radius)/2) return false;
  // else return true;
}

__device__  long long seed;
/// Intended for debugging only
__device__ __forceinline__ uint simpleRandom(uint val){
    long long a = 1103515245;
    long long c = 12345;
    long long m = 4294967295l; //2**32 - 1
    seed = (a * (val+seed) + c) % m;
    return seed;
}

  /// Computes indexes to acces 2D array, based on threadIdx and blockIdx.
  /// Morover, threads in a warp will be arranged in a rectangle (rather than in single line as with the naive implementation).
__device__ const Point2D<uint> getImageIndexes(){
  const uint threadID = threadIdx.x + threadIdx.y * blockDim.x;
  const uint warpWidth = 4; //user defined constant, representing desired width of the recatangular warp (2,4,8 are only reasonable values for the following formula)
  const uint blockWidth = blockDim.x * warpWidth;
  ASSERT (blockDim.x == 32); //following formula works only when blockDim.x is 32 
  const uint inblock_idx_x = (-threadID % (warpWidth * warpWidth) + threadID % blockWidth) / warpWidth + threadID % warpWidth;
  const uint inblock_idx_y = (threadID / blockWidth) * warpWidth + (threadID / warpWidth) % warpWidth;
  const uint idx_x = blockDim.x * blockIdx.x + inblock_idx_x;
  const uint idx_y = blockDim.y * blockIdx.y + inblock_idx_y;
  // { //debug
  //   uint warpid = threadID / warpSize;
  //   if(idx.x < 8 && idx.y < 8){
  //     printf("bw:%d\n", blockWidth);
  //     printf("%d\t%d\t%d\t%d\t%d\n", threadIdx.x, threadIdx.y, threadID ,dx, dy);
  //   }
  // }
  return Point2D<uint>(idx_x, idx_y);
}

template <class Real> __device__ __forceinline__ void fractalRenderMain(uint** output, long outputPitch, uint width, uint height, Real left_bottom_x, Real left_bottom_y, Real right_top_x, Real right_top_y, uint dwell, uint superSamplingLevel, bool adaptiveSS, bool visualiseSS, float* randomSamples, uint renderRadius, uint focus_x, uint focus_y, bool isDoublePrecision)
// todo: usporadat poradi paramateru, cudaXXObjects predavat pointrem, ne kopirovanim (tohle rozmyslet, mozna je to takhle dobre)
//  todo ma to fakt hodne pointeru, mnoho z nich je pritom pro vsechny launche stejny - nezdrzuje tohle? omezene registry a tak
{
  //TODO vypada to, ze tenhle kernel dela neco spatne v levem krajnim sloupci (asi v nultem warpu?)
  const Point idx = getImageIndexes();
  if(idx.x >= width || idx.y >= height) return;
  // if(idx.x == 0 && idx.y == 0){
  //   printf();
  // }
  if(!isWithinRadius(idx.x, idx.y, width, height, renderRadius, focus_x, focus_y)) return;

  //We are in a complex plane from (left_bottom) to (right_top), so we scale the pixels to it
  Real pixelWidth = (right_top_x - left_bottom_x) / (Real) width;
  Real pixelHeight = (right_top_y - left_bottom_y) / (Real) height;

  const uint adaptiveTreshold = 10;
  uint r[adaptiveTreshold];
  uint adaptivnessUsed = 0;

  uint escapeTimeSum = 0;
  //uint randomSamplePixelsIdx = (idx.y * width + idx.x)*MAX_SS_LEVEL;
  //superSamplingLevel = 1;
  ASSERT (superSamplingLevel <= MAX_SS_LEVEL);
  for(uint i = 0; i < superSamplingLevel; i++){
    Real random_xd = i / (Real) superSamplingLevel; //not really random, just uniform
    Real random_yd = random_xd;
    //Real random_xd = randomSamples[randomSamplePixelsIdx + i];
    //Real random_yd = randomSamples[randomSamplePixelsIdx + i + superSamplingLevel/2];
    Real cx = left_bottom_x + (idx.x + random_xd)  * pixelWidth;
    Real cy = right_top_y - (idx.y + random_yd) * pixelHeight;

    uint escapeTime = escape(dwell, cx, cy);
    escapeTimeSum += escapeTime;
    if(i < adaptiveTreshold){
      r[i] = escapeTime;
    }

    if(i == adaptiveTreshold && adaptiveSS){ //decide whether to continue with supersampling or not
      Real mean = escapeTimeSum / (i+1);
      Real dispersion = computeDispersion(r, i, mean);
      __ALL(dispersion <= 0.01);
      superSamplingLevel = i+1; //effectively disabling high SS and storing info about actual number of samples taken
      adaptivnessUsed = ColorsARGB::WHITE; 
    }else{ //else we are on an chaotic edge, thus as many samples as possible are needed
        adaptivnessUsed = ColorsARGB::BLACK;
    }
  }
  uint mean = escapeTimeSum / superSamplingLevel;  

  /*
  if(adaptivnessUsed && visualiseSS){
    resultColor = adaptivnessUsed;
  }*/
  /*if(idx_x < 10 && idx_y < 10){
    printf("%f\t", randomSample);
    __syncthreads();
    if(idx_x == 0 && idx_y == 0)
      printf("\n");
  }*/

  uint* pOutput = ((uint*)((char*)output + idx.y * outputPitch)) + idx.x;
  *pOutput = mean;
}


extern "C"
__global__ void fractalRenderMainFloat(uint** output, long outputPitch, uint width, uint height, float left_bottom_x, float left_bottom_y, float right_top_x, float right_top_y, uint dwell, uint superSamplingLevel, bool adaptiveSS, bool visualiseSS, float* randomSamples, uint renderRadius, uint focus_x, uint focus_y){
  fractalRenderMain<float>(output, outputPitch, width, height, left_bottom_x, left_bottom_y, right_top_x, right_top_y, dwell, superSamplingLevel, adaptiveSS, visualiseSS, randomSamples,  renderRadius, focus_x, focus_y, false);
}

extern "C"
__global__ void fractalRenderMainDouble(uint** output, long outputPitch, uint width, uint height, double left_bottom_x, double left_bottom_y, double right_top_x, double right_top_y, uint dwell, uint superSamplingLevel, bool adaptiveSS, bool visualiseSS, float* randomSamples, uint renderRadius, uint focus_x, uint focus_y){
  fractalRenderMain<double>(output, outputPitch, width, height, left_bottom_x, left_bottom_y, right_top_x, right_top_y, dwell, superSamplingLevel, adaptiveSS, visualiseSS, randomSamples,  renderRadius, focus_x, focus_y, true);

}

extern "C"
__global__ void compose(uint** inputMain, long inputMainPitch, uint** inputBcg, long inputBcgPitch, cudaSurfaceObject_t surfaceOutput, uint width, uint height, cudaSurfaceObject_t colorPalette, uint paletteLength, uint dwell, uint mainRenderRadius, uint focus_x, uint focus_y){
  const uint idx_x = blockDim.x * blockIdx.x + threadIdx.x;
  const uint idx_y = blockDim.y * blockIdx.y + threadIdx.y;
  if(idx_x >= width || idx_y >= height) return;

  /*
  const uint blurSize = 4;
  
  const uint convolution[blurSize][blurSize] = {
      //  {1,2,1},
      //  {2,4,2},
      //  {1,2,1}
      {0,0,0},
      {0,1,0},
      {0,0,0}
  };
  const uint convolutionDivisor = 1;

  uint sum = 0;
  #pragma unroll
  for(uint i = -blurSize/2; i < blurSize/2; i++){ 
    #pragma unroll
    for(uint j = -blurSize/2; j < blurSize/2; j++){
      uint x = max(0,min(width,idx_x + i));
      uint y = max(0,min(height,idx_y + j));
      uint* pInput1 = (uint*)((char*)input1 + y * input1pitch) + x;
      sum += (*pInput1) * convolution[i+blurSize/2][j+blurSize/2];
    }
  }
  uint result;
  result = sum / convolutionDivisor;
  */
  //choose result from one or two

  uint* pResult;
  if(isWithinRadius(idx_x, idx_y, width, height, mainRenderRadius, focus_x, focus_y)){
    pResult = (uint*)((char*)inputMain + idx_y * inputMainPitch) + idx_x;
  }else{
    pResult = (uint*)((char*)inputBcg + idx_y * inputBcgPitch) + idx_x;
  }
  uint result = *pResult;

  uint paletteIdx = paletteLength - (result % paletteLength) - 1;
  ASSERT(paletteIdx >=0);
  ASSERT(paletteIdx < paletteLength);
  uint resultColor;
  surf2Dread(&resultColor, colorPalette, paletteIdx * sizeof(uint), 0);
  if(result == dwell)
    resultColor = ColorsARGB::YELLOW;

  surf2Dwrite(resultColor, surfaceOutput, idx_x * sizeof(uint), idx_y);
}

extern "C"
__global__ void blur(){}

extern "C"
__global__ void fractalRenderUnderSampled(uint** output, long outputPitch, uint width, uint height, float left_bottom_x, float left_bottom_y, float right_top_x, float right_top_y, uint dwell, uint underSamplingLevel)
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

  uint escapeTime = escape<float>(dwell, cx, cy);

  for(uint x = 0; x < underSamplingLevel; x++){
    for(uint y = 0; y < underSamplingLevel; y++){
      //surf2Dwrite(resultColor, surfaceOutput, (idx_x + x) * sizeof(unsigned uint), (idx_y+y));
      uint* pOutput = ((uint*)((char*)output + (idx_y+y) * outputPitch)) + (idx_x+x);
      *pOutput = escapeTime;
    }
  }

}


extern "C"
__global__ void init(){

}