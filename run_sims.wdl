version 1.0

# * Structs
import "./structs.wdl"
import "./tasks.wdl"

# * task cosi2_run_one_sim_block 
task cosi2_run_one_sim_block {
  meta {
    description: "Run one block of cosi2 simulations for one demographic model."
    email: "ilya_shl@alum.mit.edu"
  }

  parameter_meta {
    # Inputs
    ## required
    paramFile: "parts cosi2 parameter file (concatenated to form the parameter file)"
    recombFile: "recombination map"
    simBlockId: "an ID of this simulation block (e.g. block number in a list of blocks)."

    ## optional
    numRepsPerBlock: "number of simulations in this block"
    maxAttempts: "max number of attempts to simulate forward frequency trajectory before failing"

    # Outputs
    replicaInfos: "array of replica infos"
  }

  input {
    File         paramFileCommon
    File         paramFile
    File         recombFile
    String       simBlockId
    String       modelId
    Int          blockNum
    Int          numBlocks
    Int          numRepsPerBlock = 1
    Int          numCpusPerBlock = numRepsPerBlock
    Int          maxAttempts = 10000000
    Int          repAttemptTimeoutSeconds = 300
    Int          repTimeoutSeconds = 3600

    String       memoryPerBlock = "3 GB"
    Int          preemptible = 3
  }
  File         taskScript = "./runcosi.py"

  # cosi2_docker: currently defined by misc/cms2-work-archive/dockstore-tool-cosi2/Dockerfile
  String  cosi2_docker = "quay.io/ilya_broad/dockstore-tool-cosi2@sha256:11df3a646c563c39b6cbf71490ec5cd90c1025006102e301e62b9d0794061e6a"
  String tpedPrefix = "tpeds__${simBlockId}"

  command <<<
    set -ex -o pipefail

    python3 "~{taskScript}" --paramFileCommon "~{paramFileCommon}" --paramFile "~{paramFile}" --recombFile "~{recombFile}" \
      --simBlockId "~{simBlockId}" --modelId "~{modelId}" --blockNum "~{blockNum}" --numRepsPerBlock "~{numRepsPerBlock}" \
      --numBlocks "~{numBlocks}" --maxAttempts "~{maxAttempts}" --repAttemptTimeoutSeconds "~{repAttemptTimeoutSeconds}" \
      --repTimeoutSeconds "~{repTimeoutSeconds}" --tpedPrefix "~{tpedPrefix}" --outJson "replicaInfos.json"
  >>>

  output {
    Array[ReplicaInfo]+ replicaInfos = read_json("replicaInfos.json").replicaInfos
    Array[File]+ simulated_hapsets = prefix(tpedPrefix + "__tar_gz__rep_", range(numRepsPerBlock))

#    String      cosi2_docker_used = ""
  }
  runtime {
#    docker: "quay.io/ilya_broad/cms-dev:2.0.1-15-gd48e1db-is-cms2-new"
    disks: "local-disk 10 HDD"
    docker: cosi2_docker
    memory: memoryPerBlock
    cpu: numCpusPerBlock
    dx_instance_type: "mem1_ssd1_v2_x4"
    preemptible: preemptible
    volatile: true  # FIXME: not volatile if random seeds specified
  }
}

# * task get_pops_info

# ** task get_pops_info implemenation
task get_pops_info {
  meta {
    description: "Extract population ids from cosi2 simulator param file"
  }
  input {
    File paramFile_demographic_model
    Array[File] paramFiles_selection

  }
  File get_pops_info_script = "./get_pops_info.py"
  String modelId = "model_"+basename(paramFile_demographic_model, ".par")
  String pops_info_fname = modelId + ".pops_info.json"
  command <<<
    set -ex -o pipefail

    python3 "~{get_pops_info_script}" --dem-model "~{paramFile_demographic_model}" \
       --sweep-defs ~{sep=" " paramFiles_selection} --out-pops-info "~{pops_info_fname}"
  >>>
  output {
    PopsInfo pops_info = read_json("${pops_info_fname}")["pops_info"]
  }
  runtime {
    docker: "quay.io/ilya_broad/cms@sha256:fc4825edda550ef203c917adb0b149cbcc82f0eeae34b516a02afaaab0eceac6"  # selscan=1.3.0a09
    memory: "500 MB"
    cpu: 1
    disks: "local-disk 1 HDD"
  }
}

workflow run_sims_wf {
  meta {
    description: "Run simulations"
    email: "ilya_shl@alum.mit.edu"
  }
# ** parameter_meta
  # parameter_meta {
  #   experimentId: "String identifying this computational experiment; used to name output files."
  #   experiment_description: "Free-from string describing the analysis"
  #   paramFile_demographic_model: "The unvarying part of the parameter file"
  #   modelId: "String identifying the demographic model"
  #   paramFiles_selection: "The varying part of the parameter file, appended to paramFileCommon; first element represents neutral model."
  #   recombFile: "Recombination map from which map of each simulated region is sampled"
  #   nreps_neutral: "Number of neutral replicates to simulate"
  #   nreps: "Number of replicates for _each_ non-neutral file in paramFiles"
  # }

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
  }

# ** Bookkeeping calls
# *** call create_tar_gz as save_input_files
  call tasks.create_tar_gz as save_input_files {
    input:
       files = flatten([[paramFile_demographic_model, paramFile_neutral, recombFile],
                        paramFiles_selection]),
       out_basename = modelId
  }

# *** call get_pops_info
  call get_pops_info {
    input:
       paramFile_demographic_model=paramFile_demographic_model,
       paramFiles_selection=paramFiles_selection
  }

  #PopsInfo pops_info = get_pops_info.pops_info
  # Array[Int] pop_ids = pops_info.pop_ids
  # Array[Int] pop_idxes = range(length(pop_ids))
  # Int n_pops = length(pop_ids)
  # Array[Pair[Int, Int]] pop_pairs = pops_info.pop_pairs
  # Int n_pop_pairs = length(pop_pairs)

  ####################################################
  # Run neutral sims
  ####################################################

# ** Run neutral sims
  Int numBlocksNeutral = nreps_neutral / numRepsPerBlock
  scatter(blockNum in range(numBlocksNeutral)) {
    call cosi2_run_one_sim_block as run_neutral_sims {
      input:
      paramFileCommon=paramFile_demographic_model,
      paramFile=paramFile_neutral,
      recombFile=recombFile,

      modelId=modelId+"_neutral",
      blockNum=blockNum,
      simBlockId=modelId+"_neutral__block_"+blockNum+"__of_"+numBlocksNeutral,
      numBlocks=numBlocksNeutral,

      maxAttempts=maxAttempts,
      repAttemptTimeoutSeconds=repAttemptTimeoutSeconds,
      repTimeoutSeconds=repTimeoutSeconds,
      numRepsPerBlock=numRepsPerBlock,
      numCpusPerBlock=numCpusPerBlock,
      memoryPerBlock=memoryPerBlock,
      preemptible=preemptible
    }
  }

  ####################################################
  # Run selection sims
  ####################################################

# ** Run selection sims
  Int numBlocks = nreps / numRepsPerBlock

  scatter(paramFile in paramFiles_selection) {
    scatter(blockNum in range(numBlocks)) {
      call cosi2_run_one_sim_block as run_selection_sims {
	input:
	paramFileCommon = paramFile_demographic_model,
	paramFile = paramFile,
	recombFile=recombFile,
	modelId=modelId+"_"+basename(paramFile, ".par"),
	blockNum=blockNum,
	simBlockId=modelId+"_"+basename(paramFile, ".par")+"__block_"+blockNum+"__of_"+numBlocks,
	numBlocks=numBlocks,
	maxAttempts=maxAttempts,
	repAttemptTimeoutSeconds=repAttemptTimeoutSeconds,
	repTimeoutSeconds=repTimeoutSeconds,
	numRepsPerBlock=numRepsPerBlock,
	numCpusPerBlock=numCpusPerBlock,
	memoryPerBlock=memoryPerBlock,
	preemptible=preemptible
      }
    }  # scatter(blockNum in range(numBlocks)) 
  } # scatter(paramFile in paramFiles_selection)

# ** Workflow outputs
  output {
# *** Bookkeeping outputs
    File saved_input_files = save_input_files.out_tar_gz
# *** Simulation outputs
    HapsetsBundle simulated_hapsets_bundle = object {
      hapsets_bundle_id: "sim.cosi2." + modelId,
      pops_info: get_pops_info.pops_info,
      neutral_hapsets: flatten(run_neutral_sims.simulated_hapsets),
      neutral_hapsets_trim_margin_bp: neutral_hapsets_trim_margin_bp,
      selection_hapsets: run_selection_sims.simulated_hapsets
    }

    # Array[Pair[ReplicaInfo,File]] selection_sims = 
    #     zip(flatten(run_selection_sims.replicaInfos),
    #         flatten(run_selection_sims.region_haps_tar_gzs))

    #Array[File] neutral_sims_tar_gzs = flatten(run_neutral_sims.region_haps_tar_gzs)
    #Array[ReplicaInfo] neutral_sims_replica_infos = flatten(run_neutral_sims.replicaInfos)
    #Array[ReplicaInfo] selection_sims_replica_infos = flatten(run_selection_sims.replicaInfos)
    #Int n_neutral_sims_succeeded = length(select_all(compute_cms2_components_for_neutral.ihs[0]))
  }
}
