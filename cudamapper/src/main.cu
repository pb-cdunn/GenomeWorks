/*
* Copyright (c) 2019, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include <algorithm>
#include <iostream>
#include <string>
#include <deque>
#include <mutex>
#include <future>
#include <thread>
#include <atomic>

#include <omp.h>

#include <claragenomics/utils/cudautils.hpp>
#include <claragenomics/utils/signed_integer_utils.hpp>
#include <claragenomics/utils/threadsafe_containers.hpp>

#include <claragenomics/cudaaligner/aligner.hpp>
#include <claragenomics/cudaaligner/alignment.hpp>

#include <claragenomics/cudamapper/index.hpp>
#include <claragenomics/cudamapper/matcher.hpp>
#include <claragenomics/cudamapper/overlapper.hpp>

#include "application_parameters.cuh"
#include "cudamapper_utils.hpp"
#include "index_batcher.cuh"
#include "overlapper_triggered.hpp"

namespace claragenomics
{
namespace cudamapper
{

namespace
{

void run_alignment_batch(DefaultDeviceAllocator allocator,
                         std::mutex& overlap_idx_mtx,
                         std::vector<Overlap>& overlaps,
                         const io::FastaParser& query_parser,
                         const io::FastaParser& target_parser,
                         int32_t& overlap_idx,
                         const int32_t max_query_size, const int32_t max_target_size,
                         std::vector<std::string>& cigar, const int32_t batch_size)
{
    int32_t device_id;
    CGA_CU_CHECK_ERR(cudaGetDevice(&device_id));
    cudaStream_t stream;
    CGA_CU_CHECK_ERR(cudaStreamCreate(&stream));
    std::unique_ptr<cudaaligner::Aligner> batch =
        cudaaligner::create_aligner(
            max_query_size,
            max_target_size,
            batch_size,
            cudaaligner::AlignmentType::global_alignment,
            allocator,
            stream,
            device_id);
    while (true)
    {
        int32_t idx_start = 0, idx_end = 0;
        // Get the range of overlaps for this batch
        {
            std::lock_guard<std::mutex> lck(overlap_idx_mtx);
            if (overlap_idx == get_size<int32_t>(overlaps))
            {
                break;
            }
            else
            {
                idx_start   = overlap_idx;
                idx_end     = std::min(idx_start + batch_size, get_size<int32_t>(overlaps));
                overlap_idx = idx_end;
            }
        }
        for (int32_t idx = idx_start; idx < idx_end; idx++)
        {
            const Overlap& overlap         = overlaps[idx];
            const io::FastaSequence query  = query_parser.get_sequence_by_id(overlap.query_read_id_);
            const io::FastaSequence target = target_parser.get_sequence_by_id(overlap.target_read_id_);
            const char* query_start        = &query.seq[overlap.query_start_position_in_read_];
            const int32_t query_length     = overlap.query_end_position_in_read_ - overlap.query_start_position_in_read_;
            const char* target_start       = &target.seq[overlap.target_start_position_in_read_];
            const int32_t target_length    = overlap.target_end_position_in_read_ - overlap.target_start_position_in_read_;
            cudaaligner::StatusType status = batch->add_alignment(query_start, query_length, target_start, target_length,
                                                                  false, overlap.relative_strand == RelativeStrand::Reverse);
            if (status != cudaaligner::success)
            {
                throw std::runtime_error("Experienced error type " + std::to_string(status));
            }
        }
        // Launch alignment on the GPU. align_all is an async call.
        batch->align_all();
        // Synchronize all alignments.
        batch->sync_alignments();
        const std::vector<std::shared_ptr<cudaaligner::Alignment>>& alignments = batch->get_alignments();
        {
            CGA_NVTX_RANGE(profiler, "copy_alignments");
            for (int32_t i = 0; i < get_size<int32_t>(alignments); i++)
            {
                cigar[idx_start + i] = alignments[i]->convert_to_cigar();
            }
        }
        // Reset batch to reuse memory for new alignments.
        batch->reset();
    }
    CGA_CU_CHECK_ERR(cudaStreamDestroy(stream));
}

/// \brief performs gloval alignment between overlapped regions of reads
/// \param overlaps List of overlaps to align
/// \param query_parser Parser for query reads
/// \param target_parser Parser for target reads
/// \param num_alignment_engines Number of parallel alignment engines to use for alignment
/// \param cigar Output vector to store CIGAR string for alignments
/// \param allocator The allocator to allocate memory on the device
void align_overlaps(DefaultDeviceAllocator allocator,
                    std::vector<Overlap>& overlaps,
                    const io::FastaParser& query_parser,
                    const io::FastaParser& target_parser,
                    int32_t num_alignment_engines,
                    std::vector<std::string>& cigar)
{
    // Calculate max target/query size in overlaps
    int32_t max_query_size  = 0;
    int32_t max_target_size = 0;
    for (const auto& overlap : overlaps)
    {
        int32_t query_overlap_size  = overlap.query_end_position_in_read_ - overlap.query_start_position_in_read_;
        int32_t target_overlap_size = overlap.target_end_position_in_read_ - overlap.target_start_position_in_read_;
        if (query_overlap_size > max_query_size)
            max_query_size = query_overlap_size;
        if (target_overlap_size > max_target_size)
            max_target_size = target_overlap_size;
    }

    // Heuristically calculate max alignments possible with available memory based on
    // empirical measurements of memory needed for alignment per base.
    const float memory_per_base = 0.03f; // Estimation of space per base in bytes for alignment
    float memory_per_alignment  = memory_per_base * max_query_size * max_target_size;
    size_t free, total;
    CGA_CU_CHECK_ERR(cudaMemGetInfo(&free, &total));
    const size_t max_alignments = (static_cast<float>(free) * 85 / 100) / memory_per_alignment; // Using 85% of available memory
    int32_t batch_size          = std::min(get_size<int32_t>(overlaps), static_cast<int32_t>(max_alignments)) / num_alignment_engines;
    std::cerr << "Aligning " << overlaps.size() << " overlaps (" << max_query_size << "x" << max_target_size << ") with batch size " << batch_size << std::endl;

    int32_t overlap_idx = 0;
    std::mutex overlap_idx_mtx;

    // Launch multiple alignment engines in separate threads to overlap D2H and H2D copies
    // with compute from concurrent engines.
    std::vector<std::future<void>> align_futures;
    for (int32_t t = 0; t < num_alignment_engines; t++)
    {
        align_futures.push_back(std::async(std::launch::async,
                                           &run_alignment_batch,
                                           allocator,
                                           std::ref(overlap_idx_mtx),
                                           std::ref(overlaps),
                                           std::ref(query_parser),
                                           std::ref(target_parser),
                                           std::ref(overlap_idx),
                                           max_query_size,
                                           max_target_size,
                                           std::ref(cigar),
                                           batch_size));
    }

    for (auto& f : align_futures)
    {
        f.get();
    }
}

/// OverlapsAndCigars - packs overlaps and cigars together so they can be passed to writer thread more easily
struct OverlapsAndCigars
{
    std::vector<Overlap> overlaps;
    std::vector<std::string> cigars;
};

/// \brief does overlapping and matching for pairs of query and target indices from device_batch
/// \param device_batch
/// \param device_cache data will be loaded into cache within the function
/// \param application_parameters
/// \param overlaps_and_cigars_to_write overlaps and cigars are output here
/// \param cuda_stream
void process_one_device_batch(const IndexBatch& device_batch,
                              IndexCacheDevice& device_cache,
                              const ApplicationParameters& application_parameters,
                              ThreadsafeProducerConsumer<OverlapsAndCigars>& overlaps_and_cigars_to_write,
                              cudaStream_t cuda_stream)
{
    const std::vector<IndexDescriptor>& query_index_descriptors  = device_batch.query_indices;
    const std::vector<IndexDescriptor>& target_index_descriptors = device_batch.target_indices;

    // fetch indices for this batch from host memory
    device_cache.generate_query_cache_content(query_index_descriptors);
    device_cache.generate_target_cache_content(target_index_descriptors);

    // process pairs of query and target indices
    for (const IndexDescriptor& query_index_descriptor : query_index_descriptors)
    {
        for (const IndexDescriptor& target_index_descriptor : target_index_descriptors)
        {
            // if doing all-to-all skip pairs in which target batch has smaller id than query batch as it will be covered by symmetry
            if (!application_parameters.all_to_all || target_index_descriptor.first_read() >= query_index_descriptor.first_read())
            {
                std::shared_ptr<Index> query_index  = device_cache.get_index_from_query_cache(query_index_descriptor);
                std::shared_ptr<Index> target_index = device_cache.get_index_from_target_cache(target_index_descriptor);

                // find anchors and overlaps
                auto matcher = Matcher::create_matcher(application_parameters.allocator,
                                                       *query_index,
                                                       *target_index,
                                                       cuda_stream);

                std::vector<Overlap> overlaps;
                OverlapperTriggered overlapper(application_parameters.allocator,
                                               cuda_stream);
                overlapper.get_overlaps(overlaps,
                                        matcher->anchors(),
                                        application_parameters.min_residues,
                                        application_parameters.min_overlap_len,
                                        application_parameters.min_bases_per_residue,
                                        application_parameters.min_overlap_fraction);

                // free up memory taken by matcher
                matcher.reset(nullptr);

                // Align overlaps
                std::vector<std::string> cigar;
                if (application_parameters.alignment_engines > 0)
                {
                    cigar.resize(overlaps.size());
                    CGA_NVTX_RANGE(profiler, "align_overlaps");
                    align_overlaps(application_parameters.allocator,
                                   overlaps,
                                   *application_parameters.query_parser,
                                   *application_parameters.target_parser,
                                   application_parameters.alignment_engines,
                                   cigar);
                }

                // pass overlaps and cigars to writer thread
                overlaps_and_cigars_to_write.add_new_element({std::move(overlaps), std::move(cigar)});
            }
        }
    }
}

/// \brief loads one batch into host memory and then processes its device batches one by one
/// \param batch
/// \param application_parameters
/// \param host_cache data will be loaded into cache within the function
/// \param device_cache data will be loaded into cache within the function
/// \param overlaps_and_cigars_to_write overlaps and cigars are output here
/// \param cuda_stream
void process_one_batch(const BatchOfIndices& batch,
                       const ApplicationParameters& application_parameters,
                       IndexCacheHost& host_cache,
                       IndexCacheDevice& device_cache,
                       ThreadsafeProducerConsumer<OverlapsAndCigars>& overlaps_and_cigars_to_write,
                       cudaStream_t cuda_stream)
{
    const IndexBatch& host_batch                  = batch.host_batch;
    const std::vector<IndexBatch>& device_batches = batch.device_batches;

    // load indices into host memory
    host_cache.generate_query_cache_content(host_batch.query_indices,
                                            device_batches.front().query_indices);
    host_cache.generate_target_cache_content(host_batch.target_indices,
                                             device_batches.front().target_indices);

    // process device batches one by one
    for (const IndexBatch& device_batch : batch.device_batches)
    {
        process_one_device_batch(device_batch,
                                 device_cache,
                                 application_parameters,
                                 overlaps_and_cigars_to_write,
                                 cuda_stream);
    }
}

/// \brief does post-processing and writes data to output
/// \param device_id
/// \param application_parameters
/// \param overlaps_and_cigars_to_write new data is added as it gets available
/// \param output_mutex controls access to output to prevent race conditions
void writer_thread_function(const std::int32_t device_id,
                            const ApplicationParameters& application_parameters,
                            ThreadsafeProducerConsumer<OverlapsAndCigars>& overlaps_and_cigars_to_write,
                            std::mutex& output_mutex)
{
    // This function is expected to run in a separate thread so set current device in order to avoid problems
    CGA_CU_CHECK_ERR(cudaSetDevice(device_id));

    // keep processing data as it arrives
    cga_optional_t<OverlapsAndCigars> data_to_write = overlaps_and_cigars_to_write.get_next_element();
    while (data_to_write) // if optional is empty that means that there will be no more overlaps to process and the thread can finish
    {
        std::vector<Overlap>& overlaps         = data_to_write->overlaps;
        const std::vector<std::string>& cigars = data_to_write->cigars;

        // Overlap post processing - add overlaps which can be combined into longer ones.
        Overlapper::post_process_overlaps(data_to_write->overlaps);

        // write to output
        {
            print_paf(overlaps,
                      cigars,
                      *application_parameters.query_parser,
                      *application_parameters.query_parser,
                      application_parameters.kmer_size,
                      output_mutex);
        }

        data_to_write = overlaps_and_cigars_to_write.get_next_element();
    }
}

/// \brief controls one GPU
///
/// Each thread is resposible for one GPU. It takes one batch, processes it and passes it to writer_thread.
/// It keeps doing this as long as there are available batches. It also controls the writer_thread.
///
/// \param device_id
/// \param batches_of_indices
/// \param application_parameters
/// \param output_mutex
/// \param cuda_stream
void worker_thread_function(const std::int32_t device_id,
                            ThreadsafeDataProvider<BatchOfIndices>& batches_of_indices,
                            const ApplicationParameters& application_parameters,
                            std::mutex& output_mutex,
                            cudaStream_t cuda_stream)
{
    // This function is expected to run in a separate thread so set current device in order to avoid problems
    CGA_CU_CHECK_ERR(cudaSetDevice(device_id));

    // divide OMP threads among GPU-controlling threads
    omp_set_num_threads(omp_get_max_threads() / application_parameters.num_devices);

    // create host_cache, data is not loaded at this point but later as each batch gets processed
    auto host_cache = std::make_shared<IndexCacheHost>(application_parameters.all_to_all,
                                                       application_parameters.allocator,
                                                       application_parameters.query_parser,
                                                       application_parameters.target_parser,
                                                       application_parameters.kmer_size,
                                                       application_parameters.windows_size,
                                                       true, // hash_representations
                                                       application_parameters.filtering_parameter,
                                                       cuda_stream);

    // create host_cache, data is not loaded at this point but later as each batch gets processed
    IndexCacheDevice device_cache(application_parameters.all_to_all,
                                  host_cache);

    // data structure used to exchnage data with writer_thread
    ThreadsafeProducerConsumer<OverlapsAndCigars> overlaps_and_cigars_to_write;

    // writer_thread runs in the background and writes overlaps and cigars to output as they become available in overlaps_and_cigars_to_write
    std::thread writer_thread(writer_thread_function,
                              device_id,
                              std::ref(application_parameters),
                              std::ref(overlaps_and_cigars_to_write),
                              std::ref(output_mutex));

    // keep processing batches of indices until there are none left
    cga_optional_t<BatchOfIndices> batch_of_indices = batches_of_indices.get_next_element();
    while (batch_of_indices) // if optional is empty that means that there are no more batches to process and the thread can finish
    {
        std::cerr << "Device " << device_id << " took new batch" << std::endl; // TODO: possible race condition, switch to logging library

        process_one_batch(batch_of_indices.value(),
                          application_parameters,
                          *host_cache,
                          device_cache,
                          overlaps_and_cigars_to_write,
                          cuda_stream);

        batch_of_indices = batches_of_indices.get_next_element();
    }

    // tell writer thread that there will be no more overlaps and it can finish once it has written all overlaps
    overlaps_and_cigars_to_write.signal_pushed_last_element();

    writer_thread.join();

    // by this point all GPU work should anyway be done as writer_thread also finished and all GPU work had to be done before last values could be written
    CGA_CU_CHECK_ERR(cudaStreamSynchronize(cuda_stream));
}

} // namespace

int main(int argc, char* argv[])
{
    logging::Init();

    const ApplicationParameters parameters(argc, argv);

    std::mutex output_mutex;

    // split work into batches
    // TODO: explain in more details
    ThreadsafeDataProvider<BatchOfIndices> batches_of_indices(generate_batches_of_indices(parameters.query_indices_in_host_memory,
                                                                                          parameters.query_indices_in_device_memory,
                                                                                          parameters.target_indices_in_host_memory,
                                                                                          parameters.target_indices_in_device_memory,
                                                                                          parameters.query_parser,
                                                                                          parameters.target_parser,
                                                                                          parameters.index_size * 1'000'000,        // value was in MB
                                                                                          parameters.target_index_size * 1'000'000, // value was in MB
                                                                                          parameters.all_to_all));

    // explicitly assign one stream to each GPU
    std::vector<cudaStream_t> cuda_streams(parameters.num_devices);

    // create worker threads (one thread per device)
    // these thread process batches_of_indices one by one
    std::vector<std::thread> worker_threads;
    for (std::int32_t device_id = 0; device_id < parameters.num_devices; ++device_id)
    {
        CGA_CU_CHECK_ERR(cudaSetDevice(device_id));
        CGA_CU_CHECK_ERR(cudaStreamCreate(&cuda_streams[device_id]));
        worker_threads.emplace_back(worker_thread_function,
                                    device_id,
                                    std::ref(batches_of_indices),
                                    std::ref(parameters),
                                    std::ref(output_mutex),
                                    cuda_streams[device_id]);
    }

    // wait for all work to be done
    for (std::int32_t device_id = 0; device_id < parameters.num_devices; ++device_id)
    {
        CGA_CU_CHECK_ERR(cudaSetDevice(device_id));
        worker_threads[device_id].join();
        CGA_CU_CHECK_ERR(cudaStreamDestroy(cuda_streams[device_id])); // no need to sync, it should be done at the end of worker_threads
    }

    return 0;
}

} // namespace cudamapper
} // namespace claragenomics

/// \brief main function
/// main function cannot be in a namespace so using this function to call actual main function
int main(int argc, char* argv[])
{
    return claragenomics::cudamapper::main(argc, argv);
}
