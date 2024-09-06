version 1.0

# * Notes

#
# tofix:

#   - maybe do not store replicaInfos in metadata unless needed
#   - separate the component computation workflow since need to also do this for tpeds from real data
#     - though, could represent neutral real regions and neutral sims and selected real regions as selected sims, with the
#       putative selected pop indicated?   so, separate putative selpop for a sim, from the rest of sim info which
#       can be optional.

#   - compute normalization for both pop1-pop2 and pop2-pop1 since freq binning is only done on 

#   - add compression of scores files

#   - add proper automated CI with deployment to terra and tagging of workflow versions by code version and saving of version as output
#   - add ability to run things with caching locally

#
#   - add collation step
#   - add automatic generation of summary plots
#        - including for the distribution of present-day freqs, and other params chosen from distributions
#

#   - fix odd ihs norm scores
#   - add taking max of relevant xpehh scores

#   - add ability to define super-pops for comparison
#   - add steps to compute 

#
#   - break up computation of components
#

#
#   - fix norm program to:
#      - not load all files in memory
#      - use accurate accumulators for sum and sum-of-sq


#
# Terms and abbreviations:
#
#    haps - haplotypes
#    sims - simulations
#    reps - simulation replicas
#    comps, components - component test statistics of CMS
#

#
# jvitti's score norming incl xpehh
# /idi/sabeti-scratch/jvitti/cms/cms/dists/scores_func.py
#

#
#      - add norming of metrics beyond ihs
#

#   - fix workflow:
#      - group norm computation into blocks, then flatten
#

#
# WDL workflow: cms2_component_scores
#
# Computation of CMS2 component scores
#

import "./tasks.wdl"
import "./compute_normalization_stats.wdl"
import "./component_stats_for_sel_sims.wdl"

# * workflow run_sims_and_compute_cms2_components
workflow compute_cms2_components_wf {
  meta {
    description: "Compute CMS2 component scores"
    email: "ilya_shl@alum.mit.edu"
  }
# ** parameter_meta

# ** inputs
  input {
    #
    # Component score computation params
    #

    #Array[File] region_haps_tar_gzs
    #Array[File] neutral_region_haps_tar_gzs

    HapsetsBundle hapsets_bundle

    ComponentComputationParams component_computation_params = object {
      n_bins_ihs: 20,
      n_bins_nsl: 20,
      n_bins_delihh: 20,
      isafe_extra_flags: "--MaxGapSize 50000"
    }

    #Map[String,Boolean] include_components = {"ihs": true, "ihh12": true, "nsl": true, "delihh": true, "xpehh": true, "fst": true, "delDAF": true, "derFreq": true}

    Int hapset_block_size = 2
  }

# ** Compute normalization stats
# *** Compute one-pop CMS2 components for neutral sims
  call compute_normalization_stats.compute_normalization_stats_wf {
    input:
    out_fnames_prefix=hapsets_bundle.hapsets_bundle_id,
    pops_info=hapsets_bundle.pops_info,
    neutral_hapsets=hapsets_bundle.neutral_hapsets,

    component_computation_params=component_computation_params,
    trim_margin_bp=hapsets_bundle.neutral_hapsets_trim_margin_bp,

    hapset_block_size=hapset_block_size,
  }

# ** Component stats for selection sims
  call component_stats_for_sel_sims.component_stats_for_sel_sims_wf {
    input:
    out_fnames_prefix=hapsets_bundle.hapsets_bundle_id,
    selection_sims=hapsets_bundle.selection_hapsets,
    pops_info=hapsets_bundle.pops_info,

    component_computation_params=component_computation_params,

    norm_bins_ihs=compute_normalization_stats_wf.norm_bins_ihs,
    norm_bins_nsl=compute_normalization_stats_wf.norm_bins_nsl,
    norm_bins_ihh12=compute_normalization_stats_wf.norm_bins_ihh12,
    norm_bins_delihh=compute_normalization_stats_wf.norm_bins_delihh,
    norm_bins_xpehh=compute_normalization_stats_wf.norm_bins_xpehh,

    one_pop_bin_stats_sel_pop_used=compute_normalization_stats_wf.one_pop_bin_stats_sel_pop_used,
    two_pop_bin_stats_sel_pop_used=compute_normalization_stats_wf.two_pop_bin_stats_sel_pop_used,
    two_pop_bin_stats_alt_pop_used=compute_normalization_stats_wf.two_pop_bin_stats_alt_pop_used,
  }

# ** Workflow outputs
  output {
    PopsInfo pops_info_used = hapsets_bundle.pops_info
    Array[File] all_hapsets_component_stats_h5_blocks = component_stats_for_sel_sims_wf.all_hapsets_component_stats_h5_blocks
  }
}
