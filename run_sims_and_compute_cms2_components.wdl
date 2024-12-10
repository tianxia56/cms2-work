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

import "./run_sims.wdl"
import "./tasks.wdl"
import "./compute_normalization_stats.wdl"
import "./component_stats_for_sel_sims.wdl"

# * workflow run_sims_and_compute_cms2_components
workflow run_sims_and_compute_cms2_components_wf {
  meta {
    description: "Run simulations and compute CMS2 component scores"
    email: "ilya_shl@alum.mit.edu"
  }
# ** parameter_meta
  parameter_meta {
    experimentId: "String identifying this computational experiment; used to name output files."
    experiment_description: "Free-from string describing the analysis"
    paramFile_demographic_model: "The unvarying part of the parameter file"
    modelId: "String identifying the demographic model"
    paramFiles_selection: "The varying part of the parameter file, appended to paramFileCommon; first element represents neutral model."
    recombFile: "Recombination map from which map of each simulated region is sampled"
    nreps_neutral: "Number of neutral replicates to simulate"
    nreps: "Number of replicates for _each_ non-neutral file in paramFiles"
  }

# ** inputs
  input {
    #
    # Simulation params
    #

    String experimentId = "default"
    String experiment_description = "an experiment"
    File paramFile_demographic_model
    File paramFile_neutral
    String modelId = "model_"+basename(paramFile_demographic_model, ".par")
    Array[File] paramFiles_selection
    File recombFile
    Int nreps_neutral
    Int nreps
    Int neutral_hapsets_trim_margin_bp = 50000
    Int maxAttempts = 10000000
    Int numRepsPerBlock = 1
    Int numCpusPerBlock = numRepsPerBlock
    Int repAttemptTimeoutSeconds = 600
    Int repTimeoutSeconds = 3600
    String       memoryPerBlock = "3 GB"
    Int preemptible = 3

    #
    # Component score computation params
    #

    #Array[File] region_haps_tar_gzs
    #Array[File] neutral_region_haps_tar_gzs

    #Map[String,Boolean] include_components = {"ihs": true, "ihh12": true, "nsl": true, "delihh": true, "xpehh": true, "fst": true, "delDAF": true, "derFreq": true}

    ComponentComputationParams component_computation_params

    Int hapset_block_size = 2
  }


  ####################################################
  # Run neutral sims
  ####################################################

# ** Call the simulations
  call run_sims.run_sims_wf as sims_wf {
    input:
    experimentId = experimentId,
    experiment_description = experiment_description,
    paramFile_demographic_model = paramFile_demographic_model,
    paramFile_neutral = paramFile_neutral,
    modelId=modelId,
    paramFiles_selection=paramFiles_selection,
    recombFile=recombFile,
    nreps_neutral=nreps_neutral,
    nreps=nreps,
    neutral_hapsets_trim_margin_bp=neutral_hapsets_trim_margin_bp,
    maxAttempts=maxAttempts,
    numRepsPerBlock=numRepsPerBlock,
    numCpusPerBlock=numCpusPerBlock,
    repTimeoutSeconds=repTimeoutSeconds,
    repAttemptTimeoutSeconds=repAttemptTimeoutSeconds,
    memoryPerBlock=memoryPerBlock,
    preemptible=preemptible
  }

# ** Compute normalization stats
# *** Compute one-pop CMS2 components for neutral sims
  call compute_normalization_stats.compute_normalization_stats_wf {
    input:
    out_fnames_prefix=modelId,
    pops_info=sims_wf.simulated_hapsets_bundle.pops_info,
    neutral_hapsets=sims_wf.simulated_hapsets_bundle.neutral_hapsets,

    component_computation_params=component_computation_params,
    hapset_block_size=hapset_block_size
  }

# ** Component stats for selection sims
  call component_stats_for_sel_sims.component_stats_for_sel_sims_wf {
    input:
    out_fnames_prefix=sims_wf.simulated_hapsets_bundle.hapsets_bundle_id,
    selection_sims=sims_wf.simulated_hapsets_bundle.selection_hapsets,
    pops_info=sims_wf.simulated_hapsets_bundle.pops_info,

    component_computation_params=component_computation_params,

    norm_bins_ihs=compute_normalization_stats_wf.norm_bins_ihs,
    norm_bins_nsl=compute_normalization_stats_wf.norm_bins_nsl,
    norm_bins_ihh12=compute_normalization_stats_wf.norm_bins_ihh12,
    norm_bins_delihh=compute_normalization_stats_wf.norm_bins_delihh,
    norm_bins_xpehh=compute_normalization_stats_wf.norm_bins_xpehh,

    one_pop_bin_stats_sel_pop_used=compute_normalization_stats_wf.one_pop_bin_stats_sel_pop_used,
    two_pop_bin_stats_sel_pop_used=compute_normalization_stats_wf.two_pop_bin_stats_sel_pop_used,
    two_pop_bin_stats_alt_pop_used=compute_normalization_stats_wf.two_pop_bin_stats_alt_pop_used
  }

# ** Workflow outputs
  output {
# *** Bookkeeping outputs
    PopsInfo pops_info = sims_wf.simulated_hapsets_bundle.pops_info
# *** Simulation outputs
    #Array[File] neutral_sims_tar_gzs = sims_wf.neutral_sims_tar_gzs
    #Array[File] selection_sims_tar_gzs = sims_wf.selection_sims_tar_gzs
    #Array[ReplicaInfo] neutral_sims_replica_infos = flatten(run_neutral_sims.replicaInfos)
    #Array[ReplicaInfo] selection_sims_replica_infos = flatten(run_selection_sims.replicaInfos)
    #Int n_neutral_sims_succeeded = length(select_all(compute_cms2_components_for_neutral.ihs[0]))
# *** Component scores
    #Array[File?] sel_normed_and_collated = component_stats_for_sel_sims_wf.sel_normed_and_collated
    #Array[File?] sel_sim_region_haps_tar_gzs = component_stats_for_sel_sims_wf.sel_sim_region_haps_tar_gzs
    #Array[CMS2_Components_Result?] sel_components_results = sel_components_result
    # Array[File] all_hapsets_component_stats_h5_blocks = 
    # component_stats_for_sel_sims_wf.all_hapsets_component_stats_h5_blocks
    Array[File] all_hapsets_component_stats_tsv_gz_blocks =
    component_stats_for_sel_sims_wf.all_hapsets_component_stats_tsv_gz_blocks
    Array[File] all_hapsets_metadata_tsv_gz_blocks =
    component_stats_for_sel_sims_wf.all_hapsets_metadata_tsv_gz_blocks
  }
}
