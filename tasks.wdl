version 1.0

import "./structs.wdl"

# * task compute_one_pop_cms2_components
task compute_one_pop_cms2_components {
  meta {
    description: "Compute one-pop CMS2 component scores assuming selection in a given pop"
  }
  input {
    Array[File]+ hapsets
    Pop sel_pop
    ComponentComputationParams component_computation_params
    Array[String] components = ["ihs", "nsl", "ihh12", "delihh", "derFreq", "iSAFE"]
  }
  File script = "./compute_cms2_components.py"
  File misc_utils = "./misc_utils.py"  # !UnusedDeclaration

  command <<<
    set -ex -o pipefail

    python3 "~{script}" --hapsets @~{write_lines(hapsets)} \
      --sel-pop ~{sel_pop.pop_id} --components ~{sep=' ' components} \
      --component-computation-params "~{write_json(component_computation_params)}" \
      --checkpoint-file "checkpoint.tar"
  >>>

  output {
    Array[File]+ replicaInfos = glob("*.replicaInfo.json")
    Array[File]+ ihs = glob("*.ihs.out")
    Array[File]+ nsl = glob("*.nsl.out")
    Array[File]+ ihh12 = glob("*.ihh12.out")
    Array[File]+ delihh = glob("*.delihh.out")
    Array[File]+ derFreq = glob("*.derFreq.tsv")
    Array[File]+ iSAFE = glob("*.iSAFE.out")
    Array[File]+ hapset_vcf = glob("*.vcf.gz")  # for debugging
    Array[File]+ hapset_sample_case_txt = glob("*.case.txt")  # for debugging
    Array[File]+ hapset_sample_cont_txt = glob("*.cont.txt")  # for debugging
    Pop sel_pop_used = sel_pop
    Boolean sanity_check = ((length(replicaInfos) == length(hapsets)) &&
                            (length(ihs) == length(hapsets)) &&
                            (length(nsl) == length(hapsets)) &&
                            (length(ihh12) == length(hapsets)) &&
                            (length(delihh) == length(hapsets)) &&
                            (length(derFreq) == length(hapsets)) &&
                            (length(iSAFE) == length(hapsets)))
    Array[Int]+ sanity_check_assert = if sanity_check then [1] else []
  }

  runtime {
    #docker: "quay.io/broad_cms_ci/cms@sha256:fc4825edda550ef203c917adb0b149cbcc82f0eeae34b516a02afaaab0eceac6"  # selscan=1.3.0a09
    docker: "quay.io/broad_cms_ci/cms:cms2-docker-component-stats-aced0918ac0afd34f7cbb3031e3b044ac7e686cc"  # selscan=1.3.0a09
    preemptible: 3
    memory: "16 GB"
    cpu: 1
    disks: "local-disk 50 HDD"
    checkpointFile: "checkpoint.tar"  # !UnknownRuntimeKey
  }
}

# * task compute_two_pop_cms2_components
task compute_two_pop_cms2_components {
  meta {
    description: "Compute cross-pop comparison CMS2 component scores"
  }
# ** inputs
  input {
    Array[File]+ hapsets
    Pop sel_pop
    Pop alt_pop
  }

  File script = "./compute_cms2_components.py"
  File misc_utils = "./misc_utils.py"  # !UnusedDeclaration

# ** command
  command <<<
    set -ex -o pipefail

    python3 "~{script}" --hapsets "@~{write_lines(hapsets)}" \
        --sel-pop "~{sel_pop.pop_id}" --alt-pop "~{alt_pop.pop_id}" \
        --components xpehh fst delDAF --checkpoint-file checkpoint.tar
  >>>

# ** outputs
  output {
    Array[File]+ replicaInfos = glob("*.replicaInfo.json")
    Array[File]+ xpehh = glob("*.xpehh.out")
    #Array[File]+ xpehh_log = glob("*.xpehh.log")
    Array[File]+ fst_and_delDAF = glob("*.fst_and_delDAF.tsv")
    Pop sel_pop_used = sel_pop
    Pop alt_pop_used = alt_pop

    Boolean sanity_check = ((length(replicaInfos) == length(hapsets)) &&
                            (length(xpehh) == length(hapsets)) &&
                            #(length(xpehh_log) == length(hapsets)) &&
                            (length(fst_and_delDAF) == length(hapsets)))
    Array[Int]+ sanity_check_assert = if sanity_check then [1] else []
  }

# ** runtime
  runtime {
    # docker: "quay.io/broad_cms_ci/cms@sha256:fc4825edda550ef203c917adb0b149cbcc82f0eeae34b516a02afaaab0eceac6"  # selscan=1.3.0a09
    docker: "quay.io/broad_cms_ci/cms:cms2-docker-component-stats-aced0918ac0afd34f7cbb3031e3b044ac7e686cc"  # selscan=1.3.0a09
    preemptible: 3
    memory: "8 GB"
    cpu: 8
    disks: "local-disk 50 HDD"
    checkpointFile: "checkpoint.tar"  # !UnknownRuntimeKey
  }
}

# * task compute_one_pop_bin_stats_for_normalization
task compute_one_pop_bin_stats_for_normalization {
  meta {
    description: "Compute the means and stds of component scores on neutral sims, for the purpose of normalization"
    email: "ilya_shl@alum.mit.edu"
  }
  input {
    String out_fnames_prefix
    Pop sel_pop
    Array[File]+ ihs_out
    Array[File]+ delihh_out
    Array[File]+ nsl_out
    Array[File]+ ihh12_out

    Int n_bins_ihs
    Int n_bins_nsl
    Int n_bins_delihh

    Int trim_margin_bp = 0
  }
  Int n_bins_ihh12 = 1
  File trim_margins_script = "./trim_margins.py"

  command <<<
    set -ex -o pipefail

    python3 "~{trim_margins_script}" --region_tsvs "@~{write_lines(ihs_out)}" --trim_margin_bp ~{trim_margin_bp} \
       --pos_col 2 --out_trimmed_tsvs_list ihs_trimmed.lst
    norm --ihs --bins ~{n_bins_ihs} --files "@ihs_trimmed.lst" --save-bins "~{out_fnames_prefix}.norm_bins_ihs.dat" \
        --only-save-bins --log "~{out_fnames_prefix}.norm_bins_ihs.log"
    tar cvzf ihs_save_trimmed.tar.gz `cat ihs_trimmed.lst`

    python3 "~{trim_margins_script}" --region_tsvs "@~{write_lines(delihh_out)}" --trim_margin_bp ~{trim_margin_bp} \
        --pos_col 2 --out_trimmed_tsvs_list delihh_trimmed.lst
    norm --ihs --bins ~{n_bins_delihh} --files "@delihh_trimmed.lst" --save-bins "~{out_fnames_prefix}.norm_bins_delihh.dat" \
        --only-save-bins --log "~{out_fnames_prefix}.norm_bins_delihh.log"
    tar cvzf delihh_save_trimmed.tar.gz `cat delihh_trimmed.lst`

    python3 "~{trim_margins_script}" --region_tsvs "@~{write_lines(nsl_out)}" --trim_margin_bp ~{trim_margin_bp} \
        --pos_col 2 --out_trimmed_tsvs_list nsl_trimmed.lst
    norm --nsl --bins ~{n_bins_nsl} --files "@nsl_trimmed.lst" --save-bins "~{out_fnames_prefix}.norm_bins_nsl.dat" \
        --only-save-bins --log "~{out_fnames_prefix}.norm_bins_nsl.log"
    tar cvzf nsl_save_trimmed.tar.gz `cat nsl_trimmed.lst`

    python3 "~{trim_margins_script}" --region_tsvs "@~{write_lines(ihh12_out)}" --trim_margin_bp ~{trim_margin_bp} \
        --pos_col 2 --has_header_line --out_trimmed_tsvs_list ihh12_trimmed.lst
    norm --ihh12 --bins ~{n_bins_ihh12} --files "@ihh12_trimmed.lst" --save-bins "~{out_fnames_prefix}.norm_bins_ihh12.dat" \
        --only-save-bins --log "~{out_fnames_prefix}.norm_bins_ihh12.log"
    tar cvzf ihh12_save_trimmed.tar.gz `cat ihh12_trimmed.lst`
  >>>

  output {
    File norm_bins_ihs = out_fnames_prefix + ".norm_bins_ihs.dat"
    File norm_bins_nsl = out_fnames_prefix + ".norm_bins_nsl.dat"
    File norm_bins_ihh12 = out_fnames_prefix + ".norm_bins_ihh12.dat"
    File norm_bins_delihh = out_fnames_prefix + ".norm_bins_delihh.dat"
    File norm_bins_ihs_log = out_fnames_prefix + ".norm_bins_ihs.log"
    File norm_bins_nsl_log = out_fnames_prefix + ".norm_bins_nsl.log"
    File norm_bins_ihh12_log = out_fnames_prefix + ".norm_bins_ihh12.log"
    File norm_bins_delihh_log = out_fnames_prefix + ".norm_bins_delihh.log"
    Pop sel_pop_used = sel_pop
    Array[File] trimmed_lists = ["ihs_trimmed.lst", "delihh_trimmed.lst", "nsl_trimmed.lst", "ihh12_trimmed.lst"]
    Array[File] trimmed_files_tar_gzs = [
    "ihs_save_trimmed.tar.gz", "delihh_save_trimmed.tar.gz", "nsl_save_trimmed.tar.gz",
    "ihh12_save_trimmed.tar.gz"
    ]
  }

  runtime {
    docker: "quay.io/broad_cms_ci/cms:cms2-docker-component-stats-aced0918ac0afd34f7cbb3031e3b044ac7e686cc"  # selscan=1.3.0a09
    #docker: "quay.io/broad_cms_ci/cms@sha256:fc4825edda550ef203c917adb0b149cbcc82f0eeae34b516a02afaaab0eceac6"  # selscan=1.3.0a09
    preemptible: 2
    memory: "8 GB"
    cpu: 1
    disks: "local-disk 50 HDD"
  }
}

# * task compute_two_pop_bin_stats_for_normalization
task compute_two_pop_bin_stats_for_normalization {
  meta {
    description: "Compute the means and stds of component scores on neutral sims, for a pop pair, for the purpose of normalization"
  }
  input {
    String out_fnames_prefix
    Pop sel_pop
    Pop alt_pop
    Array[File]+ xpehh_out

    Int trim_margin_bp = 0
  }
  Int n_bins_xpehh = 1
  File trim_margins_script = "./trim_margins.py"

  String norm_bins_xpehh_fname = "${out_fnames_prefix}__selpop_${sel_pop.pop_id}__altpop_${alt_pop.pop_id}.norm_bins_xpehh.dat"
  String norm_bins_xpehh_log_fname = "${out_fnames_prefix}__selpop_${sel_pop.pop_id}__altpop_${alt_pop.pop_id}.norm_bins_xpehh.dat"

  String norm_bins_flip_pops_xpehh_fname = "${out_fnames_prefix}__selpop_${alt_pop.pop_id}__altpop_${sel_pop.pop_id}.norm_bins_xpehh.dat"
  String norm_bins_flip_pops_xpehh_log_fname = 
  "${out_fnames_prefix}__selpop_${alt_pop.pop_id}__altpop_${sel_pop.pop_id}.norm_bins_xpehh.log"

  command <<<
    set -ex -o pipefail

    python3 "~{trim_margins_script}" --region_tsvs "@~{write_lines(xpehh_out)}" --trim_margin_bp ~{trim_margin_bp} \
        --pos_col 2 --has_header_line --out_trimmed_tsvs_list xpehh_trimmed.lst
    norm --xpehh --bins ~{n_bins_xpehh} --files "@xpehh_trimmed.lst" --save-bins "~{norm_bins_xpehh_fname}" --only-save-bins \
        --log "~{norm_bins_xpehh_log_fname}"
    norm --xpehh --xpehh-flip-pops --bins ~{n_bins_xpehh} --files "@xpehh_trimmed.lst" \
        --save-bins "~{norm_bins_flip_pops_xpehh_fname}" \
        --only-save-bins \
        --log "~{norm_bins_flip_pops_xpehh_log_fname}"
    tar cvzf xpehh_save_trimmed.tar.gz `cat xpehh_trimmed.lst`
  >>>

  output {
    File norm_bins_xpehh = norm_bins_xpehh_fname
    File norm_bins_xpehh_log = norm_bins_xpehh_log_fname
    
    File norm_bins_flip_pops_xpehh = norm_bins_flip_pops_xpehh_fname
    File norm_bins_flip_pops_xpehh_log = norm_bins_flip_pops_xpehh_log_fname

    Pop sel_pop_used = sel_pop
    Pop alt_pop_used = alt_pop

    Pop flip_pops_sel_pop_used = alt_pop
    Pop flip_pops_alt_pop_used = sel_pop

    File xpehh_trimmed_list = "xpehh_trimmed.lst"
    File xpehh_save_trimmed_tar_gz = "xpehh_save_trimmed.tar.gz"
    
  }

  runtime {
    #docker: "quay.io/broad_cms_ci/cms@sha256:fc4825edda550ef203c917adb0b149cbcc82f0eeae34b516a02afaaab0eceac6"  # selscan=1.3.0a09
    docker: "quay.io/broad_cms_ci/cms:cms2-docker-component-stats-aced0918ac0afd34f7cbb3031e3b044ac7e686cc"  # selscan=1.3.0a09
    preemptible: 2
    memory: "8 GB"
    cpu: 1
    disks: "local-disk 50 HDD"
  }
}

# * task normalize_and_collate_block

task normalize_and_collate_block {
  meta {
    description: "Normalize raw scores to neutral sims, and collate component scores into one table."
  }
  input {
    NormalizeAndCollateBlockInput inp
  }
  File normalize_and_collate_script = "./norm_and_collate_block.py"
  command <<<
    set -ex -o pipefail

    python3 "~{normalize_and_collate_script}" --input-json "~{write_json(inp)}"
  >>>  
  output {
    Array[File]+ replica_info = glob("*.normed_and_collated.replicaInfo.json")
    Array[File]+ normed_collated_stats = glob("*.normed_and_collated.tsv")
    Pop sel_pop_used = inp.sel_pop
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:cms2-docker-component-stats-aced0918ac0afd34f7cbb3031e3b044ac7e686cc"  # selscan=1.3.0a09
    #docker: "quay.io/broad_cms_ci/cms@sha256:fc4825edda550ef203c917adb0b149cbcc82f0eeae34b516a02afaaab0eceac6"  # selscan=1.3.0a09
    memory: "1 GB"
    cpu: 1
    disks: "local-disk 10 HDD"
    preemptible: 1
  }
}

struct collate_stats_and_metadata_for_all_sel_sims_input {
    String out_fnames_prefix
    Array[File]+ sel_normed_and_collated
    Array[File]+ replica_infos
}

task collate_stats_and_metadata_for_sel_sims_block {
  meta {
    description: "Collate component stats and metadata for a block of selection sims"
  }
  input {
    collate_stats_and_metadata_for_all_sel_sims_input inp
  }
  File collate_stats_and_metadata_for_sel_sims_block_script = "./collate_stats_and_metadata_for_sel_sims_block.py"
  Int max_hapset_id_len = 256
  # String hapsets_component_stats_h5_fname = inp.out_fnames_prefix + ".all_component_stats.h5"
  String hapsets_component_stats_tsv_gz_fname = inp.out_fnames_prefix + ".all_component_stats.tsv.gz"
  String hapsets_metadata_tsv_gz_fname = inp.out_fnames_prefix + ".hapsets_metadata.tsv.gz"
  command <<<
    set -ex -o pipefail

    python3 "~{collate_stats_and_metadata_for_sel_sims_block_script}" --input-json "~{write_json(inp)}" \
       --max-hapset-id-len ~{max_hapset_id_len} \
       --hapsets-component-stats-tsv-gz-fname "~{hapsets_component_stats_tsv_gz_fname}" \
       --hapsets-metadata-tsv-gz-fname "~{hapsets_metadata_tsv_gz_fname}"
  >>>
  output {
    # File hapsets_component_stats_h5 = hapsets_component_stats_h5_fname
    File hapsets_component_stats_tsv_gz = hapsets_component_stats_tsv_gz_fname
    File hapsets_metadata_tsv_gz = hapsets_metadata_tsv_gz_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:cms2-docker-component-stats-aced0918ac0afd34f7cbb3031e3b044ac7e686cc"
    memory: "4 GB"
    cpu: 1
    disks: "local-disk 25 HDD"
    preemptible: 1
  }
}

# * task create_tar_gz
task create_tar_gz {
  meta {
    description: "Combine files into a tar file"
    email: "ilya_shl@alum.mit.edu"
  }
  input {
    Array[File]+ files
    String out_basename = "out"
  }
  String out_fname_tar_gz = out_basename + ".tar.gz"
  command <<<
    set -ex -o pipefail

    tar cvfz ~{out_fname_tar_gz} ~{sep=" " files}
  >>>
  output {
    File out_tar_gz = out_fname_tar_gz
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:wget-1544c1d7a6fbb36a7f0cfebf7aa332a6e52e767d"
    memory: "500 MB"
    cpu: 1
    disks: "local-disk 1 HDD"
  }
}

task construct_pops_info_for_1KG {
  meta {
    description: "Constructs a PopsInfo struct for 1KG populations"
  }
  parameter_meta {
# ** inputs
    superpop_to_representative_pop_json: "(File) map from superpop to the pop used to represent it in model-fitting simulations"
    empirical_regions_bed: "(File) empirical regions to fetch.  Column 5 (score), if present, is interpreted as the name of the putatively selected population.  The same region may be listed multiple times to test for selection in multiple populations."

# ** outputs
    pops_info: "(PopsInfo) a PopsInfo struct giving info for 1KG pops"
  }
  input {
    File superpop_to_representative_pop_json = "./resources/superpop-to-representative-pop.json"
    File empirical_regions_bed
  }
  File construct_pops_info_for_1KG_script = "./construct_pops_info_for_1KG.py"
  String pops_info_fname = "pops_info.1KG.json"
  command <<<
    set -ex -o pipefail

    mkdir "${PWD}/hapsets"
    python3 "~{construct_pops_info_for_1KG_script}" --superpop-to-representative-pop-json "~{superpop_to_representative_pop_json}" \
       --empirical-regions-bed "~{empirical_regions_bed}" \
       --out-pops-info-json "~{pops_info_fname}"
  >>>
  output {
    PopsInfo pops_info = read_json("${pops_info_fname}")["pops_info"]  # !UnverifiedStruct
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "16 GB"
    cpu: 1
    disks: "local-disk 256 HDD"
    preemptible: 1
  }
}

task merge_likely_neutral_regions {
  meta {
    description: "Merge overlapping likely-neutral regions"
  }
  parameter_meta {
# ** inputs
    neutral_regions_bed: "(File) .bed file listing likely-neutral genomic regions"
    merge_margin_bp: "(Int) merge regions within this distance"
# ** outputs
    neutral_regions_merged_bed: "(File) list of merged likely-neutral regions"
  }
  input {
    File neutral_regions_bed
    Int merge_margin_bp = 0
  }
  String neutral_regions_merged_fname = basename(neutral_regions_bed, ".bed") + ".merged.bed"

  command <<<
    set -ex -o pipefail

    cat "~{neutral_regions_bed}" | bedtools sort -i stdin | bedtools merge -i stdin -d "~{merge_margin_bp}" \
        > "~{neutral_regions_merged_fname}"
  >>>
  output {
    File neutral_regions_merged_bed = neutral_regions_merged_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "16 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
  }
}


task slop_likely_neutral_regions {
  meta {
    description: "Add a margin to likely-neutral regions"
  }
  parameter_meta {
# ** inputs
    neutral_regions_bed: "(File) .bed file listing likely-neutral genomic regions"
    chrom_sizes: "(File) file listing chromosome sizes"
    slop_margin_bp: "(Int) slop regions by this margin"
# ** outputs
    neutral_regions_slopped_bed: "(File) list of slopped likely-neutral regions"
  }
  input {
    File neutral_regions_bed
    File chrom_sizes
    Int slop_margin_bp = 0
  }
  String neutral_regions_slopped_fname = basename(neutral_regions_bed, ".bed") + ".slopped.bed"

  command <<<
    set -ex -o pipefail

    cat "~{neutral_regions_bed}" | bedtools sort -i stdin | bedtools slop -g "~{chrom_sizes}" -i stdin -b "~{slop_margin_bp}" \
        > "~{neutral_regions_slopped_fname}"
  >>>
  output {
    File neutral_regions_slopped_bed = neutral_regions_slopped_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "16 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
  }
}

task fetch_empirical_hapsets_from_1KG {
  meta {
    description: "Fetches empirical hapsets for specified regions from 1KG, converts to hapset format"
  }
  parameter_meta {
# ** inputs
    pops_info: "(PopsInfo) information about 1KG pops, including the outgroups to compare with each pop"
    empirical_regions_bed: "(File) empirical regions to fetch.  Column 5 (score), if present, is interpreted as the name of the putatively selected population.  The same region may be listed multiple times to test for selection in multiple populations."
    sel_pop_id: "(String?) if not given, assume empirical_regions_bed are neutral, else take only regions with selection in this pop"
    # add: metadata to attach to all regions
    genetic_maps_tar_gz: "(File) genetic maps"
    superpop_to_representative_pop_json: "(File) map from superpop to the pop used to represent it in model-fitting simulations"
    chrom_vcfs: "(ChromVcfs) the vcf files"

# ** outputs
    empirical_hapsets: "(Array[File]) for each empirical region, a .tar.gz file containing one tped for each pop, and a *.replicaInfo.json file describing the hapset"
  }
  input {
    PopsInfo pops_info
    String? sel_pop_id
    File empirical_regions_bed
    String out_fnames_prefix
    File genetic_maps_tar_gz
    File superpop_to_representative_pop_json = "./resources/superpop-to-representative-pop.json"
    ChromVcfs chrom_vcfs
    File pedigree_data_ped
    File related_individuals_txt
    File pops_data_tsv
  }
  File fetch_empirical_hapsets_script = "./fetch_empirical_hapsets.py"
  String stats_cumul_json_fname = out_fnames_prefix + ".stats_cumul.json"

  command <<<
    set -ex -o pipefail

    mkdir "${PWD}/hapsets"
    python3 "~{fetch_empirical_hapsets_script}" --empirical-regions-bed "~{empirical_regions_bed}" \
       --genetic-maps-tar-gz "~{genetic_maps_tar_gz}" \
       --superpop-to-representative-pop-json "~{superpop_to_representative_pop_json}" \
       --pedigree-data-ped "~{pedigree_data_ped}" \
       --related-individuals-txt "~{related_individuals_txt}" \
       --pops-data-tsv "~{pops_data_tsv}" \
       --chrom-vcfs "~{write_json(chrom_vcfs)}" \
       --out-fnames-prefix "~{out_fnames_prefix}" \
       --out-cumul-stats-json "~{stats_cumul_json_fname}" \
       ~{"--sel-pop " + sel_pop_id} \
       --tmp-dir "${PWD}/hapsets"
    df -h
  >>>
  output {
    Array[File]+ empirical_hapsets = glob("hapsets/*.hapset.tar.gz")
    File stats_cumul_json = stats_cumul_json_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "16 GB"
    cpu: 1
    disks: "local-disk 256 HDD"
    preemptible: 1
  }
}

# task construct_empirical_neutral_regions_list_gazave14 {
#   meta {
#     description: "Construct a .bed file representing neutral empirical regions based on Gazave 2014 paper."
#   }
# }

task call_neutral_region_explorer {
  meta {
    description: "Calls Neutral Region Explorer webserver"
  }
  parameter_meta {
# ** inputs
# ** outputs
  }
  input {
    NeutralRegionExplorerParams nre_params
    String out_fnames_prefix = "nre"
  }
  File fetch_neutral_regions_nre_script = "./fetch_neutral_regions_nre.py"
  String neutral_regions_tsv_fname = out_fnames_prefix + ".neutral_regions.tsv"
  String neutral_regions_bed_fname = out_fnames_prefix + ".neutral_regions.bed"
  String nre_submitted_form_html_fname = out_fnames_prefix + ".submitted_form.html"
  String nre_results_html_fname = out_fnames_prefix + ".nre_results.html"
  String nre_results_url_fname = out_fnames_prefix + ".nre_results.url.txt"

  command <<<
    set -ex -o pipefail

    python3 "~{fetch_neutral_regions_nre_script}" --nre-params "~{write_json(nre_params)}" \
       --neutral-regions-tsv "~{neutral_regions_tsv_fname}" \
       --neutral-regions-bed "~{neutral_regions_bed_fname}" \
       --nre-submitted-form-html "~{nre_submitted_form_html_fname}" \
       --nre-results-html "~{nre_results_html_fname}" \
       --nre-results-url "~{nre_results_url_fname}"
    
  >>>
  output {
    File neutral_regions_tsv = neutral_regions_tsv_fname
    File neutral_regions_bed = neutral_regions_bed_fname
    File nre_submitted_form_html = nre_submitted_form_html_fname
    File nre_results_html = nre_results_html_fname
    String nre_results_url = read_string(nre_results_url_fname)
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:webdriver-6dba18313775d137217c8a45c4bdd53d6b4e4441"
    memory: "4 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
  }
}

task fetch_file_from_url {
  meta {
    description: "Downloads a file from a given URL.  Using an output of this ask as inputs, instead of using URLs directly, can improve reproducibility in case the contents of a URL changes or the URL becomes inaccessible, since call caching would save a copy of the file."
  }
  parameter_meta {
# ** inputs
    url: "(String) the URL from which to download a file"
    out_fname: "(String?) name of output file (defaults to basename(url))"
    sha256: "(String?) if given, fail unless the sha256 checksum of the downloaded file matches this value"
    file_metadata: "(Map[String,String]) arbitrary metadata (such as description) to associate with this file"
    wget_flags: "(String) wget options to use for downloading, such as timeout and number of retries"
# ** outputs
    file: "(File) the downloaded file"
    url_used: "(String) url from which the file was fetched"
    file_lastmod: "(File) the last-modified time of the file on the server (human-readable)"
    file_size: "(Int) size of the downloaded file in bytes"
    out_file_metadata: "(Map[String,String]) any metadata specified as input, copied to the output"
    wget_cmd_used: "(String) the full wget command used to download the file"
  }  
  input {
    String url
    String? out_fname

    String? sha256

    Map[String,String] file_metadata = {}
    String wget_flags = " -T 300 -t 20 -S "
  }
  String out_fname_here = select_first([out_fname, basename(url), "unknown_filename"])
  String out_lastmod_fname = out_fname_here + ".lastmod.txt"
  String wget_cmd_here = "wget -O " + out_fname_here + " " + wget_flags + " " + url
  String sha256_here = select_first([sha256, ""])
  
  command <<<
    set -ex -o pipefail

    ~{wget_cmd_here}

    if [ -n "~{sha256_here}" ]
    then
        echo "~{sha256_here} ~{out_fname_here}" > "~{out_fname_here}.sha256"
        sha256sum -c "~{out_fname_here}.sha256"
    fi

    # save last-modified 
    stat -c '%Y' "~{out_fname_here}" > "~{out_lastmod_fname}"
  >>>
  output {
    File file = out_fname_here
    String url_used = url
    String file_lastmod = read_string(out_lastmod_fname)
    Int file_size = round(size(file))
    Map[String,String] out_file_metadata = file_metadata
    String wget_cmd_used = wget_cmd_here
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:wget-1544c1d7a6fbb36a7f0cfebf7aa332a6e52e767d"
    memory: "4 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
    maxRetries: 6
  }
}

task fetch_file_from_google_drive {
  meta {
    description: "Downloads a file from Google Drive."
  }
  parameter_meta {
# ** inputs
    gdrive_file_id: "(String) file ID of the file"
    out_fname: "(String) name of output file"
    sha256: "(String?) if given, fail unless the sha256 checksum of the downloaded file matches this value"
    file_metadata: "(Map[String,String]) arbitrary metadata (such as description) to associate with this file"
# ** outputs
    file: "(File) the downloaded file"
    file_size: "(Int) size of the downloaded file in bytes"
    out_file_metadata: "(Map[String,String]) any metadata specified as input, copied to the output"
  }  
  input {
    String gdrive_file_id
    String out_fname

    String? sha256

    Map[String,String] file_metadata = {}
  }
  String sha256_here = select_first([sha256, ""])
  
  command <<<
    set -ex -o pipefail

    gdown -O "~{out_fname}" "~{gdrive_file_id}"

    if [ -n "~{sha256_here}" ]
    then
        echo "~{sha256_here} ~{out_fname}" > "~{out_fname}.sha256"
        sha256sum -c "~{out_fname}.sha256"
    fi
  >>>
  output {
    File file = out_fname
    Int file_size = round(size(file))
    Map[String,String] out_file_metadata = file_metadata
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:gdown-2758c0c4158238c3c968a37dd48924d54aad3b63"
    memory: "4 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
  }
}


task compute_intervals_stats {
  meta {
    description: "Compute summary stats for a set of genomic intervals files"
  }
  parameter_meta {
# ** inputs
    intervals_files: "(Array[File]+) genomic intervals files (.bed or .gff3)"

# ** outputs
    intervals_report_html: "(File) An HTML report of stats about the intervals"
  }  
  input {
    Array[File]+ intervals_files
    File? metadata_json
    String intervals_report_html_fname = basename(intervals_files[0]) + ".stats.html"
  }
  File compute_intervals_stats_script = "./compute_intervals_stats.py"

  command <<<
    set -ex -o pipefail

    python3 "~{compute_intervals_stats_script}" \
        --intervals-files "@~{write_lines(intervals_files)}" \
        ~{'--metadata-json ' + metadata_json} \
        --intervals-report-html "~{intervals_report_html_fname}"
  >>>
  output {
    File intervals_report_html = intervals_report_html_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "4 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
  }
}

task get_intervals_chroms {
  meta {
    description: "Get list of chroms used in intervals files"
  }
  parameter_meta {
# ** inputs
    intervals_files: "(Array[File]+) genomic intervals files (.bed or .gff3)"

# ** outputs
    intervals_chroms: "(Array[String]) List of intervals chroms"
  }  
  input {
    Array[File]+ intervals_files
    String intervals_chroms_fname = basename(intervals_files[0]) + ".chroms.txt"
  }
  File get_intervals_chroms_script = "./get_intervals_chroms.py"

  command <<<
    set -ex -o pipefail

    python3 "~{get_intervals_chroms_script}" \
        --intervals-files "@~{write_lines(intervals_files)}" \
        --out-intervals-chroms-txt "~{intervals_chroms_fname}"
  >>>
  output {
    Array[String] intervals_chroms = read_lines(intervals_chroms_fname)
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "4 GB"
    cpu: 1
    disks: "local-disk 8 HDD"
    preemptible: 1
  }
}

task strip_chr_prefix {
  meta {
    description: "Strip chr prefix from a bedfile"
  }
  parameter_meta {
# ** inputs
    bed_file: "(File) genomic intervals file (.bed)"

# ** outputs
    bed_file_nochr: "(File) Same bed file with chr stripped"
  }  
  input {
    File bed_file
  }

  String bed_file_nochr_fname = basename(bed_file, ".bed") + ".nochr.bed"

  command <<<
    set -ex -o pipefail

    cat "~{bed_file}" | sed s/^chr//g > "~{bed_file_nochr_fname}"
  >>>
  output {
    File bed_file_nochr = bed_file_nochr_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "8 GB"
    cpu: 1
    disks: "local-disk 16 HDD"
    preemptible: 1
  }
}

task keep_only_autosome_intervals {
  meta {
    description: "Strip non-autosome intervals from a .bed file"
  }
  parameter_meta {
# ** inputs
    bed_file: "(File) genomic intervals file (.bed)"

# ** outputs
    bed_file_onlyaut: "(File) Same bed file with only autosomes"
  }  
  input {
    File bed_file
  }

  String bed_file_onlyaut_fname = basename(bed_file, ".bed") + ".onlyaut.bed"

  command <<<
    set -ex -o pipefail

    cat "~{bed_file}" | grep ^[1-9] > "~{bed_file_onlyaut_fname}"
  >>>
  output {
    File bed_file_onlyaut = bed_file_onlyaut_fname
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "8 GB"
    cpu: 1
    disks: "local-disk 16 HDD"
    preemptible: 1
  }
}

task construct_neutral_regions_list {
  meta {
    description: "Constructs a list of likely-neutral genomic regions."
  }
  parameter_meta {
# ** inputs

# ** outputs
    neutral_regions_bed: "(File) likely-neutral regions"
  }  
  input {
    EmpiricalNeutralRegionsParams empirical_neutral_regions_params
    GenomicFeaturesForFindingEmpiricalNeutralRegions genomic_features_for_finding_empirical_neutral_regions
    String neutral_regions_bed_fname = "neutral_regions.bed"
  }
  File construct_neutral_regions_list_script = "./construct_neutral_regions_list.py"

  File empirical_neutral_regions_params_json = write_json(empirical_neutral_regions_params)

  command <<<
    set -ex -o pipefail

    python3 "~{construct_neutral_regions_list_script}" \
        --empirical-neutral-regions-params "~{empirical_neutral_regions_params_json}" \
        --genomic-features-for-finding-empirical-neutral-regions "~{write_json(genomic_features_for_finding_empirical_neutral_regions)}" \
        --neutral-regions-bed "~{neutral_regions_bed_fname}"

  >>>
  output {
    File neutral_regions_bed = neutral_regions_bed_fname

    Array[File] aux_beds = glob("*.bed")
    EmpiricalNeutralRegionsParams empirical_neutral_regions_params_used = empirical_neutral_regions_params
    File empirical_neutral_regions_params_used_json = empirical_neutral_regions_params_json
  }
  runtime {
    docker: "quay.io/broad_cms_ci/cms:common-tools-2b4d477113c453dc9e957c002f6665be20fd56fd"
    memory: "16 GB"
    cpu: 1
    disks: "local-disk 32 HDD"
    preemptible: 1
  }
}
