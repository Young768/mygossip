#pragma once

#include <vector>

#include "config.h"
#include "error_checking.hpp"
#include "common.cuh"
#include "context.cuh"
#include "all_to_all_plan.hpp"

namespace gossip {

class all2all_async_t {

    const context_t * context;

    transfer_plan_t transfer_plan;
    bool plan_valid;

public:
     all2all_async_t (
        const context_t& context_)
        : context(&context_),
          transfer_plan( all2all::default_plan(context->get_num_devices()) ),
          plan_valid( transfer_plan.valid() )
    {
        check(context->is_valid(),
              "You have to pass a valid context!");
    }

    all2all_async_t (
        const context_t& context_,
        const transfer_plan_t& transfer_plan_)
        : context(&context_),
          transfer_plan(transfer_plan_),
          plan_valid(false)
    {
        check(context->is_valid(),
              "You have to pass a valid context!");

        if(!transfer_plan.valid())
            all2all::verify_plan(transfer_plan);

        plan_valid = (get_num_devices() == transfer_plan.num_gpus()) &&
                     transfer_plan.valid();
    }

public:
    void show_plan() const {
        if(!plan_valid)
            std::cout << "WARNING: plan does fit number of gpus\n";

        transfer_plan.show_plan();
    }

public:
    template <
        typename value_t,
        typename index_t,
        typename table_t>
    bool execAsync (
        std::vector<value_t *>& srcs,                   // src[k] resides on device_ids[k]
        const std::vector<index_t  >& srcs_lens,        // src_len[k] is length of src[k]
        std::vector<value_t *>& dsts,                   // dst[k] resides on device_ids[k]
        const std::vector<index_t  >& dsts_lens,        // dst_len[k] is length of dst[k]
        std::vector<value_t *>& bufs,
        const std::vector<index_t  >& bufs_lens,
        const std::vector<std::vector<table_t> >& send_counts, // [src_gpu, partition]
        bool verbose = false
    ) const {
        if (!plan_valid) return false;

        if (!check(srcs.size() == get_num_devices(),
                    "srcs size does not match number of gpus."))
            return false;
        if (!check(srcs_lens.size() == get_num_devices(),
                    "srcs_lens size does not match number of gpus."))
            return false;
        if (!check(dsts.size() == get_num_devices(),
                    "dsts size does not match number of gpus."))
            return false;
        if (!check(dsts_lens.size() == get_num_devices(),
                    "dsts_lens size does not match number of gpus."))
            return false;
        if (!check(bufs.size() == get_num_devices(),
                    "bufs size does not match number of gpus."))
            return false;
        if (!check(bufs_lens.size() == get_num_devices(),
                    "bufs_lens size does not match number of gpus."))
            return false;        if (!check(send_counts.size() == get_num_devices(),
                    "table size does not match number of gpus."))
            return false;
        for (const auto& counts : send_counts) {
            if (!check(counts.size() == get_num_devices(),
                        "table size does not match number of gpus."))
                return false;
        }

        const auto num_phases = transfer_plan.num_steps();
        const auto num_chunks = transfer_plan.num_chunks();

        std::vector<std::vector<size_t> > src_displacements(get_num_devices(), std::vector<size_t>(get_num_devices()+1));
        // horizontal scan to get src offsets
        for (gpu_id_t gpu = 0; gpu < get_num_devices(); ++gpu) {
            for (gpu_id_t part = 0; part < get_num_devices(); ++part) {
                src_displacements[gpu][part+1] = send_counts[gpu][part]+src_displacements[gpu][part];
            }
        }
        std::vector<std::vector<size_t> > trg_displacements(get_num_devices()+1, std::vector<size_t>(get_num_devices()));
        // vertical scan to get trg offsets
        for (gpu_id_t gpu = 0; gpu < get_num_devices(); ++gpu) {
            for (gpu_id_t part = 0; part < get_num_devices(); ++part) {
                trg_displacements[part+1][gpu] = send_counts[part][gpu]+trg_displacements[part][gpu];
            }
        }

        transfer_handler<table_t> transfers(context,
                                            src_displacements,
                                            trg_displacements,
                                            send_counts,
                                            num_phases, num_chunks);

        // prepare transfers according to transfer_plan
        for (const auto& sequence : transfer_plan.transfer_sequences()) {
            transfers.push_back(sequence.seq, sequence.size, verbose);
        }

        if(verbose) {
            for (size_t p = 0; p < num_phases; ++p) {
                transfers.show_phase(p);
            }
        }

        if(!check_size(transfers.aux_offsets, bufs_lens)) return false;
        if(!check_size(transfers.trg_offsets.back(), dsts_lens)) return false;

        for (size_t p = 0; p < num_phases; ++p) {
            transfers.execute_phase(p, srcs, dsts, bufs);
        }

        return true;
    }

    gpu_id_t get_num_devices () const noexcept {
        return context->get_num_devices();
    }

    void sync () const noexcept {
        context->sync_all_streams();
    }

    void sync_hard () const noexcept {
        context->sync_hard();
    }

    const context_t& get_context() const noexcept {
        return *context;
    }
};

} // namespace
