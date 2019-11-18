/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "claragenomics/cudamapper/index_two_indices.hpp"
#include <claragenomics/utils/cudautils.hpp>
#include "index_gpu_two_indices.cuh"
#include "minimizer.hpp"

namespace claragenomics
{
namespace cudamapper
{
std::unique_ptr<IndexTwoIndices> IndexTwoIndices::create_index(const io::FastaParser& parser,
                                                               const read_id_t first_read_id,
                                                               const read_id_t past_the_last_read_id,
                                                               const std::uint64_t kmer_size,
                                                               const std::uint64_t window_size)
{
    CGA_NVTX_RANGE(profiler, "create_index");
    return std::make_unique<IndexGPUTwoIndices<Minimizer>>(parser,
                                                           first_read_id,
                                                           past_the_last_read_id,
                                                           kmer_size,
                                                           window_size);
}

std::unique_ptr<IndexTwoIndices> IndexTwoIndices::create_index()
{
    return std::make_unique<IndexGPUTwoIndices<Minimizer>>();
}
} // namespace cudamapper
} // namespace claragenomics
