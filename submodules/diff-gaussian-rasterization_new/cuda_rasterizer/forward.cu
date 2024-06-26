/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */
#include <vector>
#include "forward.h"
#include "auxiliary.h"
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
#include <cuda_runtime.h>
#include <cmath>
#include <cstdlib>
#include <curand_kernel.h>

namespace cg = cooperative_groups;
using namespace std;
// Forward method for converting the input spherical harmonics
// coefficients of each Gaussian to a simple RGB color.
__device__ glm::vec3 computeColorFromSH(int idx, int deg, int max_coeffs, const glm::vec3* means, glm::vec3 campos, const float* shs, bool* clamped)
{
	// The implementation is loosely based on code for 
	// "Differentiable Point-Based Radiance Fields for 
	// Efficient View Synthesis" by Zhang et al. (2022)
	glm::vec3 pos = means[idx];
	glm::vec3 dir = pos - campos;
	dir = dir / glm::length(dir);

	glm::vec3* sh = ((glm::vec3*)shs) + idx * max_coeffs;
	glm::vec3 result = SH_C0 * sh[0];

	if (deg > 0)
	{
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;
		result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;
			result = result +
				SH_C2[0] * xy * sh[4] +
				SH_C2[1] * yz * sh[5] +
				SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
				SH_C2[3] * xz * sh[7] +
				SH_C2[4] * (xx - yy) * sh[8];

			if (deg > 2)
			{
				result = result +
					SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
					SH_C3[1] * xy * z * sh[10] +
					SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
					SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
					SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
					SH_C3[5] * z * (xx - yy) * sh[14] +
					SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
			}
		}
	}
	result += 0.5f;

	// RGB colors are clamped to positive values. If values are
	// clamped, we need to keep track of this for the backward pass.
	clamped[3 * idx + 0] = (result.x < 0);
	clamped[3 * idx + 1] = (result.y < 0);
	clamped[3 * idx + 2] = (result.z < 0);
	return glm::max(result, 0.0f);
}

// Forward version of 2D covariance matrix computation
__device__ float3 computeCov2D(const float3& mean, float focal_x, float focal_y, float tan_fovx, float tan_fovy, const float* cov3D, const float* viewmatrix, const float kernel_ratio,const int mode)
{
	// The following models the steps outlined by equations 29
	// and 31 in "EWA Splatting" (Zwicker et al., 2002). 
	// Additionally considers aspect / scaling of viewport.
	// Transposes used to account for row-/column-major conventions.
	float3 t = transformPoint4x3(mean, viewmatrix);

	const float limx = 1.3f * tan_fovx;
	const float limy = 1.3f * tan_fovy;
	const float txtz = t.x / t.z;
	const float tytz = t.y / t.z;
	t.x = min(limx, max(-limx, txtz)) * t.z;
	t.y = min(limy, max(-limy, tytz)) * t.z;

	glm::mat3 J = glm::mat3(
		focal_x / t.z, 0.0f, -(focal_x * t.x) / (t.z * t.z),
		0.0f, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z),
		0, 0, 0);

	glm::mat3 W = glm::mat3(
		viewmatrix[0], viewmatrix[4], viewmatrix[8],
		viewmatrix[1], viewmatrix[5], viewmatrix[9],
		viewmatrix[2], viewmatrix[6], viewmatrix[10]);

	glm::mat3 T = W * J;

	glm::mat3 Vrk = glm::mat3(
		cov3D[0], cov3D[1], cov3D[2],
		cov3D[1], cov3D[3], cov3D[4],
		cov3D[2], cov3D[4], cov3D[5]);

	glm::mat3 cov = glm::transpose(T) * glm::transpose(Vrk) * T;

	// const float det_0 = max(1e-6, cov[0][0] * cov[1][1] - cov[0][1] * cov[0][1]);
	// const float det_1 = max(1e-6, (cov[0][0] + 0.3f/16) * (cov[1][1] + 0.3f/16) - cov[0][1] * cov[0][1]);
	// float coef = sqrt(det_0 / (det_1+1e-6) + 1e-6);

	// if (det_0 <= 1e-6 || det_1 <= 1e-6){
	// 	coef = 0.0f;
	// }

	// Apply low-pass filter: every Gaussian should be at least
	// one pixel wide/high. Discard 3rd row and column.
	

	if(mode==0){
		cov[0][0] += 0.3f;
		cov[1][1] += 0.3f;
	}
	else{
		cov[0][0] += 0.3f*kernel_ratio*kernel_ratio;
		cov[1][1] += 0.3f*kernel_ratio*kernel_ratio;
	}

	return { float(cov[0][0]), float(cov[0][1]), float(cov[1][1]) };
}

// Forward method for converting scale and rotation properties of each
// Gaussian to a 3D covariance matrix in world space. Also takes care
// of quaternion normalization.
__device__ void computeCov3D(const glm::vec3 scale, float mod, const glm::vec4 rot, float* cov3D)
{
	// Create scaling matrix
	glm::mat3 S = glm::mat3(1.0f);
	S[0][0] = mod * scale.x;
	S[1][1] = mod * scale.y;
	S[2][2] = mod * scale.z;

	// Normalize quaternion to get valid rotation
	glm::vec4 q = rot;// / glm::length(rot);
	float r = q.x;
	float x = q.y;
	float y = q.z;
	float z = q.w;

	// Compute rotation matrix from quaternion
	glm::mat3 R = glm::mat3(
		1.f - 2.f * (y * y + z * z), 2.f * (x * y - r * z), 2.f * (x * z + r * y),
		2.f * (x * y + r * z), 1.f - 2.f * (x * x + z * z), 2.f * (y * z - r * x),
		2.f * (x * z - r * y), 2.f * (y * z + r * x), 1.f - 2.f * (x * x + y * y)
	);

	glm::mat3 M = S * R;

	// Compute 3D world covariance matrix Sigma
	glm::mat3 Sigma = glm::transpose(M) * M;

	// Covariance is symmetric, only store upper right
	cov3D[0] = Sigma[0][0];
	cov3D[1] = Sigma[0][1];
	cov3D[2] = Sigma[0][2];
	cov3D[3] = Sigma[1][1];
	cov3D[4] = Sigma[1][2];
	cov3D[5] = Sigma[2][2];
}

// Perform initial steps for each Gaussian prior to rasterization.
template<int C>
__global__ void preprocessCUDA(int P, int D, int M,
	const float* orig_points,
	const glm::vec3* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	const float tan_fovx, float tan_fovy,
	const float focal_x, float focal_y,
	int* radii,
	float2* points_xy_image,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	float4* eigenvector,
	float2* lambda,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered,
	const int mode,
	const float kernel_ratio)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Initialize radius and touched tiles to 0. If this isn't changed,
	// this Gaussian will not be processed further.
	radii[idx] = 0;
	tiles_touched[idx] = 0;

	// Perform near culling, quit if outside.
	float3 p_view;
	if (!in_frustum(idx, orig_points, viewmatrix, projmatrix, prefiltered, p_view))
		return;

	// Transform point by projecting
	float3 p_orig = { orig_points[3 * idx], orig_points[3 * idx + 1], orig_points[3 * idx + 2] };
	float4 p_hom = transformPoint4x4(p_orig, projmatrix);
	float p_w = 1.0f / (p_hom.w + 0.0000001f);
	float3 p_proj = { p_hom.x * p_w, p_hom.y * p_w, p_hom.z * p_w };

	// If 3D covariance matrix is precomputed, use it, otherwise compute
	// from scaling and rotation parameters. 
	const float* cov3D;
	if (cov3D_precomp != nullptr)
	{
		cov3D = cov3D_precomp + idx * 6;
	}
	else
	{
		computeCov3D(scales[idx], scale_modifier, rotations[idx], cov3Ds + idx * 6);
		cov3D = cov3Ds + idx * 6;
	}

	// Compute 2D screen-space covariance matrix
	float3 cov = computeCov2D(p_orig, focal_x, focal_y, tan_fovx, tan_fovy, cov3D, viewmatrix, kernel_ratio,mode);

	// Invert covariance (EWA algorithm)
	float det = (cov.x * cov.z - cov.y * cov.y);
	if (det == 0.0f)
		return;
	float det_inv = 1.f / det;
	float3 conic = { cov.z * det_inv, -cov.y * det_inv, cov.x * det_inv };

	// Compute extent in screen space (by finding eigenvalues of
	// 2D covariance matrix). Use extent to compute a bounding rectangle
	// of screen-space tiles that this Gaussian overlaps with. Quit if
	// rectangle covers 0 tiles. 
	float mid = 0.5f * (cov.x + cov.z);

	float lambda1 = mid + sqrt(max(0.1f, mid * mid - det));
	float lambda2 = mid - sqrt(max(0.1f, mid * mid - det));
	float my_radius = ceil(3.f * sqrt(max(lambda1, lambda2)));
	lambda1 = mid + sqrt(max(0.0f, mid * mid - det));
	lambda2 = mid - sqrt(max(0.0f, mid * mid - det));

	// --------------------------------------------------------------------
	#pragma region 
	float2 evector1 = {1.0f, 0.0f};
	float2 evector2 = {0.0f, 1.0f};
	if(cov.x-(mid + sqrt(mid * mid - det))!=0){
		evector1.x = 1;
		evector1.y = ((mid + sqrt(mid * mid - det))-cov.x)/cov.y;
	}else{
		evector1.y = 1;
		evector1.x = cov.y/((mid + sqrt(mid * mid - det))-cov.x);
	}
	if(cov.x-(mid - sqrt(mid * mid - det))!=0){
		evector2.x = 1;
		evector2.y = cov.y / ((mid - sqrt(mid * mid - det))-cov.z);
	}else{
		evector2.y = 1;
		evector2.x = ((mid - sqrt(mid * mid - det))-cov.z) / cov.y;
	}

	if(lambda1<0){
		// evector1.x *= -1;
		// evector1.y *= -1;
		lambda1 *= -1;
	}
	if(lambda2<0){
		// evector2.x *= -1;
		// evector2.y *= -1;
		lambda2 *= -1;
	}
	float evector1_norm = sqrt(evector1.x*evector1.x+evector1.y*evector1.y);
	float evector2_norm = sqrt(evector2.x*evector2.x+evector2.y*evector2.y);
	evector1.x /= evector1_norm;
	evector1.y /= evector1_norm;
	evector2.x /= evector2_norm;
	evector2.y /= evector2_norm;
	#pragma endregion
    // --------------------------------------------------------------------

	float2 point_image = { ndc2Pix(p_proj.x, W), ndc2Pix(p_proj.y, H) };
	uint2 rect_min, rect_max;
	getRect(point_image, my_radius, rect_min, rect_max, grid);
	if ((rect_max.x - rect_min.x) * (rect_max.y - rect_min.y) == 0)
		return;

	// If colors have been precomputed, use them, otherwise convert
	// spherical harmonics coefficients to RGB color.
	if (colors_precomp == nullptr)
	{
		glm::vec3 result = computeColorFromSH(idx, D, M, (glm::vec3*)orig_points, *cam_pos, shs, clamped);
		rgb[idx * C + 0] = result.x;
		rgb[idx * C + 1] = result.y;
		rgb[idx * C + 2] = result.z;
	}

	// Store some useful helper data for the next steps.
	depths[idx] = p_view.z;
	radii[idx] = my_radius;
	points_xy_image[idx] = point_image;
	// Inverse 2D covariance and opacity neatly pack into one float4
	conic_opacity[idx] = { conic.x, conic.y, conic.z, opacities[idx]};
	tiles_touched[idx] = (rect_max.y - rect_min.y) * (rect_max.x - rect_min.x);
	eigenvector[idx] = {evector1.x, evector1.y, evector2.x, evector2.y};
	lambda[idx] = {lambda1, lambda2};
}

// Main rasterization method. Collaboratively works on one tile per
// block, each thread treats one pixel. Alternates between fetching 
// and rasterizing data.
template <uint32_t CHANNELS>
__global__ void __launch_bounds__(BLOCK_X * BLOCK_Y)
renderCUDA(
	const uint2* __restrict__ ranges,
	const uint32_t* __restrict__ point_list,
	int W, int H,
	const int mode,
	const float2* __restrict__ points_xy_image,
	const float* __restrict__ features,
	const float4* __restrict__ conic_opacity,
	const float4* __restrict__ eigenvector,
	const float2* __restrict__ lambda,
	float* __restrict__ final_T,
	uint32_t* __restrict__ n_contrib,
	const float* __restrict__ bg_color,
	float* __restrict__ out_color,
	float* __restrict__ subpixel_flag)
{
	// Identify current tile and associated min/max pixel range.
	auto block = cg::this_thread_block();
	uint32_t horizontal_blocks = (W + BLOCK_X - 1) / BLOCK_X;
	uint2 pix_min = { block.group_index().x * BLOCK_X, block.group_index().y * BLOCK_Y };
	uint2 pix_max = { min(pix_min.x + BLOCK_X, W), min(pix_min.y + BLOCK_Y , H) };
	uint2 pix = { pix_min.x + block.thread_index().x, pix_min.y + block.thread_index().y };
	uint32_t pix_id = W * pix.y + pix.x;
	float2 pixf = { (float)pix.x, (float)pix.y };

	// Check if this thread is associated with a valid pixel or outside.
	bool inside = pix.x < W&& pix.y < H;
	// Done threads can help with fetching, but don't rasterize
	bool done = !inside;

	// Load start/end range of IDs to process in bit sorted list.
	uint2 range = ranges[block.group_index().y * horizontal_blocks + block.group_index().x];
	const int rounds = ((range.y - range.x + BLOCK_SIZE - 1) / BLOCK_SIZE);
	int toDo = range.y - range.x;
	
	// Allocate storage for batches of collectively fetched data.
	__shared__ int collected_id[BLOCK_SIZE];
	__shared__ float2 collected_xy[BLOCK_SIZE];
	__shared__ float4 collected_conic_opacity[BLOCK_SIZE];
	__shared__ float4 collected_eigenvector[BLOCK_SIZE];
	__shared__ float2 collected_lambda[BLOCK_SIZE];

	// Initialize helper variables
	float T = 1.0f;
	float4 T4 = {1.0f,1.0f,1.0f,1.0f};
	uint32_t contributor = 0;
	uint32_t last_contributor = 0;
	float C[CHANNELS] = { 0 };
	
	// ------------------------------------------------------------------------
	#pragma region 
	const int sub = 3;
	float sub_float =3.0f;
	__shared__ float collected_subpixel_flag[BLOCK_SIZE*sub*sub];
	for(int sub_idx=0;sub_idx<sub*sub;++sub_idx){
			collected_subpixel_flag[block.thread_rank()*sub*sub+sub_idx] = subpixel_flag[block.thread_rank()*sub*sub+sub_idx];
		}
	block.sync();
	#pragma endregion
	// ------------------------------------------------------------------------

	// Iterate over batches until all done or range is complete
	for (int i = 0; i < rounds; i++, toDo -= BLOCK_SIZE)
	{
		// End if entire block votes that it is done rasterizing
		int num_done = __syncthreads_count(done);
		if (num_done == BLOCK_SIZE)
			break;

		// Collectively fetch per-Gaussian data from global to shared
		int progress = i * BLOCK_SIZE + block.thread_rank();
		if (range.x + progress < range.y)
		{
			int coll_id = point_list[range.x + progress];
			collected_id[block.thread_rank()] = coll_id;
			collected_xy[block.thread_rank()] = points_xy_image[coll_id];
			collected_conic_opacity[block.thread_rank()] = conic_opacity[coll_id];
			collected_eigenvector[block.thread_rank()] = eigenvector[coll_id];
			collected_lambda[block.thread_rank()] = lambda[coll_id];
		}
		block.sync();
		
		// Iterate over current batch
		for (int j = 0; !done && j < min(BLOCK_SIZE, toDo); j++)
		{
			// Keep track of current position in range
			contributor++;

			// Resample using conic matrix (cf. "Surface 
			// Splatting" by Zwicker et al., 2001)
			float2 xy = collected_xy[j];
			
			// int col = int((0.5-d.x)*17);
			// int row = int((0.5-d.y)*17);
			float4 con_o = collected_conic_opacity[j];
			float4 eigen_vector_o = collected_eigenvector[j];
			float2 lambda = collected_lambda[j];


			// --------------------------------------------------------------------
			if (mode == 0){
				float2 d_raw = { xy.x - pixf.x, xy.y - pixf.y };
				float power_raw = -0.5f * (con_o.x * d_raw.x * d_raw.x + con_o.z * d_raw.y * d_raw.y) - con_o.y * d_raw.x * d_raw.y;
				if (power_raw > 0.0f) continue;
				float alpha_raw = min(0.99f, con_o.w * exp(power_raw));
				if (alpha_raw < 1.0f / 255.0f) continue;

				float test_T = T * (1 - alpha_raw);
				if (test_T < 0.0001f)
				{
					done = true;
					continue;
				}

				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += features[collected_id[j] * CHANNELS + ch] * alpha_raw * T;	
				T = test_T;
			}
			else if (mode==3){
				float2 d_raw = { xy.x - pixf.x, xy.y - pixf.y };
				float power_raw = -0.5f * (con_o.x * d_raw.x * d_raw.x + con_o.z * d_raw.y * d_raw.y) - con_o.y * d_raw.x * d_raw.y;
				if (power_raw > 0.0f) continue;
				float alpha_raw = min(0.99f, con_o.w * exp(power_raw));
				if (alpha_raw < 1.0f / 255.0f) continue;

				float test_T = T * (1 - alpha_raw);
				if (test_T < 0.0001f)
				{
					done = true;
					continue;
				}

				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += features[collected_id[j] * CHANNELS + ch] * alpha_raw * T;	
				T = test_T;
			}
            // --------------------------------------------------------------------


			// --------------------------------------------------------------------
			else if (mode==1){
				float2 d_raw = { xy.x - pixf.x, xy.y - pixf.y };
				float power_raw = -0.5f * (con_o.x * d_raw.x * d_raw.x + con_o.z * d_raw.y * d_raw.y) - con_o.y * d_raw.x * d_raw.y;
				if (power_raw > 0.0f) continue;
				float alpha_raw = min(0.99f, con_o.w * exp(power_raw));
				if (alpha_raw < 1.0f / 255.0f) continue;

				float2 x_range = {1000.0f, -1000.0f};
				float2 y_range = {1000.0f, -1000.0f};
				float2 d = { -xy.x + pixf.x, -xy.y+pixf.y };
				float dot1 = d.x * eigen_vector_o.x + d.y * eigen_vector_o.y;
				float dot2 = d.x * eigen_vector_o.z + d.y * eigen_vector_o.w;
				x_range.x = min(x_range.x, dot1-0.5f);
				x_range.y = max(x_range.y, dot1+0.5f);
				y_range.x = min(y_range.x, dot2-0.5f);
				y_range.y = max(y_range.y, dot2+0.5f);
				x_range.x = x_range.x / lambda.x;
				x_range.y = x_range.y / lambda.x;
				y_range.x = y_range.x / lambda.y;
				y_range.y = y_range.y / lambda.y;

				float alpha = 2*3.1416*con_o.w *\
							(sqrt(lambda.x)*(0.5 * erfc(-x_range.y * sqrt(0.5f)) - 0.5 * erfc(-x_range.x * sqrt(0.5f))) *\
							sqrt(lambda.y)*(0.5 * erfc(-y_range.y * sqrt(0.5f)) - 0.5 * erfc(-y_range.x * sqrt(0.5f))))/\
							((x_range.y*lambda.x-x_range.x*lambda.x)*(y_range.y*lambda.y-y_range.x*lambda.y));

				alpha = min(0.99f, alpha);
				if (alpha < 1.0f / 255.0f) continue;

				float test_T = T * (1 - alpha);
				if (test_T < 0.0001f)
				{
					done = true;
					continue;
				}
				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += features[collected_id[j] * CHANNELS + ch] * alpha * T;
				T = test_T;
			}

			else {
				float2 d_raw = { xy.x - pixf.x, xy.y - pixf.y };
				float power_raw = -0.5f * (con_o.x * d_raw.x * d_raw.x + con_o.z * d_raw.y * d_raw.y) - con_o.y * d_raw.x * d_raw.y;
				if (power_raw > 0.0f) continue;
				float alpha_raw = min(0.99f, con_o.w * exp(power_raw));
				if (alpha_raw < 1.0f / 255.0f) continue;
				int cnt = 0;
				float alpha_with_T_all = 0.0f;
				for(int i1=int(-sub/2);i1<=int(sub/2);++i1){
					if(done==true) break;
					for(int j1=int(-sub/2);j1<=int(sub/2);++j1){
						if(collected_subpixel_flag[block.thread_rank()*sub*sub+(j1+int(sub/2))*sub+i1+int(sub/2)] < 0.0001f){
							cnt += 1;
							if(cnt>=sub*sub){done=true;break;}
						}
						float2 d = {xy.x-(pixf.x+float(i1)*(1/sub_float)), xy.y-(pixf.y+float(j1)*(1/sub_float))};
						float power = -0.5f * (con_o.x * d.x * d.x + con_o.z * d.y * d.y) - con_o.y * d.x * d.y;
						if (power > 0.0f) continue;
						float alpha = min(0.99f, con_o.w * exp(power));
						if (alpha< 1.0f / 255.0f) continue;
						alpha_with_T_all += alpha * collected_subpixel_flag[block.thread_rank()*sub*sub+(j1+int(sub/2))*sub+i1+int(sub/2)];
						collected_subpixel_flag[block.thread_rank()*sub*sub+(j1+int(sub/2))*sub+i1+int(sub/2)] *= (1 - alpha);
					}
				}
				
				for (int ch = 0; ch < CHANNELS; ch++)
					C[ch] += features[collected_id[j] * CHANNELS + ch] * alpha_with_T_all/(sub*sub);
			}
			// --------------------------------------------------------------------


		
			
			// Keep track of last range entry to update this
			// pixel.
			last_contributor = contributor;
		}
	}

	// All threads that treat valid pixel write out their final
	// rendering data to the frame and auxiliary buffers.
	if (inside)
	{
		final_T[pix_id] = T;
		n_contrib[pix_id] = last_contributor;
		for (int ch = 0; ch < CHANNELS; ch++)
			out_color[ch * H * W + pix_id] = C[ch] + T * bg_color[ch];
	}
}

void FORWARD::render(
	const dim3 grid, dim3 block,
	const uint2* ranges,
	const uint32_t* point_list,
	int W, int H,
	const int mode,
	const float2* means2D,
	const float* colors,
	const float4* conic_opacity,
	const float4* eigenvector,
	const float2* lambda,
	float* final_T,
	uint32_t* n_contrib,
	const float* bg_color,
	float* out_color,
	float* subpixel_flag)
{
	
    // printf("Thread rank in block: %f\n", subpixel_flag[0]);
   
	renderCUDA<NUM_CHANNELS> << <grid, block >> > (
		ranges,
		point_list,
		W, H,
		mode,
		means2D,
		colors,
		conic_opacity,
		eigenvector,
		lambda,
		final_T,
		n_contrib,
		bg_color,
		out_color,
		subpixel_flag);
}

void FORWARD::preprocess(int P, int D, int M,
	const float* means3D,
	const glm::vec3* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	const float focal_x, float focal_y,
	const float tan_fovx, float tan_fovy,
	int* radii,
	float2* means2D,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	float4* eigenvector,
	float2* lambda,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered,
	const int mode,
	const float kernel_ratio)
{
	preprocessCUDA<NUM_CHANNELS> << <(P + 255) / 256, 256 >> > (
		P, D, M,
		means3D,
		scales,
		scale_modifier,
		rotations,
		opacities,
		shs,
		clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix, 
		projmatrix,
		cam_pos,
		W, H,
		tan_fovx, tan_fovy,
		focal_x, focal_y,
		radii,
		means2D,
		depths,
		cov3Ds,
		rgb,
		conic_opacity,
		eigenvector,
		lambda,
		grid,
		tiles_touched,
		prefiltered,
		mode,
		kernel_ratio
	);
}