version 1.0

import "./tasks.wdl"

workflow component_stats_for_sel_sims_wf {
  input {
    String out_fnames_prefix
    Array[Array[Array[File]+]+] selection_sims
    PopsInfo pops_info

    ComponentComputationParams component_computation_params

    Array[File]+ norm_bins_ihs
    Array[File]+ norm_bins_nsl
    Array[File]+ norm_bins_ihh12
    Array[File]+ norm_bins_delihh
    Array[Array[File]+]+ norm_bins_xpehh

    Array[Pop]+ one_pop_bin_stats_sel_pop_used
    Array[Array[Pop]+]+ two_pop_bin_stats_sel_pop_used
    Array[Array[Pop]+]+ two_pop_bin_stats_alt_pop_used
  }

  scatter(sel_scen_idx in range(length(selection_sims))) {
    Pop sel_pop = pops_info.sel_pops[sel_scen_idx]
    Int sel_pop_idx = pops_info.pop_id_to_idx[sel_pop.pop_id]
    scatter(sel_blk_idx in range(length(selection_sims[sel_scen_idx]))) {
      call tasks.compute_one_pop_cms2_components as compute_one_pop_cms2_components_for_selection {
	input:
	sel_pop=sel_pop,
	hapsets=selection_sims[sel_scen_idx][sel_blk_idx],
	component_computation_params=component_computation_params
      }
      scatter(alt_pop_idx in range(length(pops_info.pop_ids))) {
	if ((alt_pop_idx != sel_pop_idx)  &&  pops_info.pop_alts_used[sel_pop_idx][alt_pop_idx]) {
	  call tasks.compute_two_pop_cms2_components as compute_two_pop_cms2_components_for_selection {
	    input:
	    sel_pop=sel_pop,
	    alt_pop=pops_info.pops[alt_pop_idx],
	    hapsets=selection_sims[sel_scen_idx][sel_blk_idx]
	  }
	}
      }  # for each comparison pop

      call tasks.normalize_and_collate_block {
	input:
	  inp = object {  # struct NormalizeAndCollateBlockInput
	    pop_ids: pops_info.pop_ids,
	    sel_pop: sel_pop,

	    replica_info: compute_one_pop_cms2_components_for_selection.replicaInfos,
	    ihs_out: compute_one_pop_cms2_components_for_selection.ihs,
	    delihh_out: compute_one_pop_cms2_components_for_selection.delihh,
	    nsl_out: compute_one_pop_cms2_components_for_selection.nsl,
	    ihh12_out: compute_one_pop_cms2_components_for_selection.ihh12,
	    delihh_out: compute_one_pop_cms2_components_for_selection.delihh,
	    derFreq_out: compute_one_pop_cms2_components_for_selection.derFreq,
	    iSAFE_out: compute_one_pop_cms2_components_for_selection.iSAFE,

	    xpehh_out: select_all(compute_two_pop_cms2_components_for_selection.xpehh),
	    fst_and_delDAF_out: select_all(compute_two_pop_cms2_components_for_selection.fst_and_delDAF),

	    one_pop_components_sel_pop_used: compute_one_pop_cms2_components_for_selection.sel_pop_used,
	    two_pop_components_sel_pop_used: select_all(compute_two_pop_cms2_components_for_selection.sel_pop_used),
	    two_pop_components_alt_pop_used: select_all(compute_two_pop_cms2_components_for_selection.alt_pop_used),

	    component_computation_params: component_computation_params,

	    norm_bins_ihs: norm_bins_ihs[sel_pop_idx],
	    norm_bins_nsl: norm_bins_nsl[sel_pop_idx],
	    norm_bins_ihh12: norm_bins_ihh12[sel_pop_idx],
	    norm_bins_delihh: norm_bins_delihh[sel_pop_idx],

	    norm_bins_xpehh: norm_bins_xpehh[sel_pop_idx],

	    norm_one_pop_components_sel_pop_used: one_pop_bin_stats_sel_pop_used[sel_pop_idx],
	    norm_two_pop_components_sel_pop_used: two_pop_bin_stats_sel_pop_used[sel_pop_idx],
	    norm_two_pop_components_alt_pop_used: two_pop_bin_stats_alt_pop_used[sel_pop_idx]
	  }
       } # call tasks.normalize_and_collate_block

       call tasks.collate_stats_and_metadata_for_sel_sims_block {
	    input:
	    inp = object {  # struct collate_stats_and_metadata_for_all_sel_sims_input
	      out_fnames_prefix: out_fnames_prefix + "__selscen_" + sel_scen_idx + "__selblk_" + sel_blk_idx,
	      sel_normed_and_collated: normalize_and_collate_block.normed_collated_stats,
	      replica_infos: normalize_and_collate_block.replica_info
	    }
	}  
    }   # for each block of sel sims
    #}  # if (sel_sim.left.succeeded) 
  }  # end: scatter(sel_scen_idx in range(length(selection_sims)))


  output {
    # Array[File]+ all_hapsets_component_stats_h5_blocks =
    # flatten(collate_stats_and_metadata_for_sel_sims_block.hapsets_component_stats_h5)
    Array[File]+ all_hapsets_component_stats_tsv_gz_blocks =
    flatten(collate_stats_and_metadata_for_sel_sims_block.hapsets_component_stats_tsv_gz)
    Array[File]+ all_hapsets_metadata_tsv_gz_blocks =
    flatten(collate_stats_and_metadata_for_sel_sims_block.hapsets_metadata_tsv_gz)
  }
}
