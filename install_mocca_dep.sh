#!/bin/bash

#### start of the script ####
# conda installation @efs has already contained snakemake, perl (and perl modules)
# /efs/miniconda3/bin/conda init && source ~/.bashrc
/bin/su -c "/efs/miniconda3/bin/conda init && source ~/.bashrc" - centos

# I still need to use yum installed singularity as conda version does not work somehow
sudo yum update -y && \
    sudo yum install -y epel-release && \
    sudo yum update -y && \
    sudo yum install -y singularity

# singularity --version
# perl --version
# conda --version
# snakemake --version
#### end of the script ####
