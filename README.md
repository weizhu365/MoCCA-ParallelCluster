# Deployment of MoCCA-SV snakemake pipeline at AWS ParallelCluster
---
## Overview
___
### Description
This tutorial is to show how to deploy [MoCCA-SV snakemake pipeline](https://github.com/NCI-CGR/MoCCA-SV) to the cloud platform. In this demonstration, we first show how to create a SGE cluster at AWS using the AWS ParallelCluster, and then how to deploy the MoCCA-SV pipeline on the SGE cluster.

### Dependencies
In this tutorial, you need have admin permission in your AWS account. You should have basic AWS knowledge to configure VPC, safety gorup, EC2 instance, EFS and etc.
 
### Architecture
We are going to launch a login node first and create an EFS first.  After installing essential components on EFS, we then create a SGE cluster from the login node, with one master node and two worker nodes.  Finally, remotely access the master node to run the pipeline.    

___

## Instructions
### 1. Launch an EC2 instance as the login node and install pcluster. 
There is no specific requirement for the EC2 instance to install AWS ParallelCluster later. In our case, we launch an EC2 t2.mciro instance (amzn2-ami-hvm-2.0.20200304.0-x86_64-gp2: ami-0fc61db8544a617ed) as the login node and we follow [this AWS instruction](https://docs.aws.amazon.com/parallelcluster/latest/ug/install-virtualenv.html) to install AWS ParallelCluster in a virtual environment, under the directory ***~/apc-ve***.

After you have done with the AWS ParallelCluster installation, you may confirm your success as below.
```bash
source ~/apc-ve/bin/activate

pcluster version
# 2.6.0
```

### 2. Create an EFS
It is simple to create a new EFS. You may also choose to use the existing EFS instead.  Please make sure to add rule to the safety group, so as to open NFS port 2049 to allow inbound traffic from the login node and the SGE cluster to the EFS.  The details is available [here](https://docs.aws.amazon.com/efs/latest/ug/accessing-fs-create-security-groups.html).  

You may test to mount the EFS storage to your login node to /efs: 
```bash
sudo mkdir /efs
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=30,retrans=2,noresvport,_netdev fs-XXXXXXXX.efs.us-east-1.amazonaws.com:/ /efs 
```
And move to the next step when the EFS mounting is successful. 

### 3. Pre-install MoCCA-SV dependencies to /efs
[Python, snakemake, perl and singularity](https://github.com/NCI-CGR/MoCCA-SV#ii--dependencies) are all reqired to run MoCCA-SV.  We need have them installed in the SGE cluster.  There are several way to achieve it.  One way is [Building a Custom AWS ParallelCluster AMI](https://docs.aws.amazon.com/parallelcluster/latest/ug/tutorials_02_ami_customization.html), which, however, is not ideal as updating is a common scenario in AWS. The preferred way is to [use post-install actions](https://docs.aws.amazon.com/parallelcluster/latest/ug/pre_post_install.html) called after cluster boostrap is complete. We are going to take the preferred way in this tutorial.  

To save time, we pre-install some of the required modules to /efs via conda. Briefly, we are going to install conda under /efs/miniconda3 and activate the conda installation in the boostrap script later. In this way, it also saves disk space in the master/worker nodes.  

```bash
mkdir -p /efs/dn
cd /efs/dn
sudo yum install -y perl wget libtool

wget https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh

### install conda in batch mode 
sh Miniconda3-latest-Linux-x86_64.sh -b -f -p /efs/miniconda3
source ~/.bash_profile

conda --version
# conda 4.8.2

which conda
# /efs/miniconda3/bin/conda

### Install singularity (3.5.3-1.1.el7)
sudo yum update -y && \
    sudo yum install -y epel-release && \
    sudo yum update -y && \
    sudo yum install -y singularity

singularity --version
#singularity version 3.5.3-1.1.el7

### Install snakemake and perl 
# installation of snakemake is very slow
conda install -y -c bioconda -c conda-forge snakemake

conda install -y -c bioconda perl-app-cpanminus pysam
conda install -y -c anaconda gcc_linux-64
cpanm Capture::Tiny List::MoreUtils YAML::Tiny Array::Diff

snakemake --version
# 5.11.2

which perl
# /efs/miniconda3/bin/perl

perl --version

# This is perl 5, version 26, subversion 2 (v5.26.2) built for x86_64-linux-thread-multi

# Copyright 1987-2018, Larry Wall

# Perl may be copied only under the terms of either the Artistic License or the
# GNU General Public License, which may be found in the Perl 5 source kit.

# Complete documentation for Perl, including FAQ lists, should be found on
# this system using "man perl" or "perldoc perl".  If you have access to the
# Internet, point your browser at http://www.perl.org/, the Perl Home Page.
```

We found that the singularity version installed by conda cannot work well with the snakemake pipeline. So we put its installation in the bootstrap script, as described in the section below. 

### 4. Install MoCCA-SV pipeline
The details of the MoCCA-SV pipeline is available at [github](https://github.com/NCI-CGR/MoCCA-SV). 
```bash
cd /efs
git clone https://github.com/NCI-CGR/MoCCA-SV.git
```

### 5. Create the bootstrap script
This script is to activate conda and install signualrity in the AWS ParallelCluster bootstrap actions. 

***install_mocca_dep.sh***
```bash
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
```

It is noticable that activation of the conda in the script is a little tricky.  As the script will be run as the user *root* in the bootstrap, and we want to activate the conda setting for the default user *centos*. So we cannot directly run:

*/efs/miniconda3/bin/conda init && source ~/.bashrc*

but run the command below instead in the script: 

*/bin/su -c "/efs/miniconda3/bin/conda init && source ~/.bashrc" - ***centos****

Besides, if you use different EC2 instance, you may change default user name, such as, *ec2-user* or *ubuntu*, accordingly in the script. 

Finally, we need upload the script to S3. The script at S3 will be specified in the ParallelCluster configure file later. 
```bash
aws s3 cp --acl public-read /efs/scripts/install_mocca_dep.sh s3://mocca-cluster-setup/
```

### 6. Configure the SGE cluster
The most critial step is in this step: cluster configuration.     

```ini
[aws]
aws_region_name = us-east-1

[global]
cluster_template = default
update_check = true
sanity_check = true

[aliases]
ssh = ssh {CFN_USER}@{MASTER_IP} {ARGS} -i ~/.ssh/xxx.pem # use your own key pair

[cluster default]
key_name = nci-hpc
base_os = centos7
master_instance_type = t2.large
compute_instance_type = t2.xlarge
initial_queue_size = 2
maintain_initial_size = true
vpc_settings = test
efs_settings = customfs
dcv_settings = default
post_install = https://xxxxxxxx.s3.amazonaws.com/install_mocca_dep.sh # url link to your script
post_install_args = "R curl wget"

[dcv default]
enable = master

[vpc test]
vpc_id = vpc-xxxxxxxx # put your vpc id
master_subnet_id = subnet-xxxxxxx # your subnet id

[efs customfs]
shared_dir = efs
efs_fs_id = fs-xxxxxxxx # your efs id
```

In this configuration, I have also added [NICE DCV](https://aws.amazon.com/hpc/dcv/) function to the cluster.  NICE DCV provides a remote-descktop like feature to access the master node of the SGE cluster, which is really ***NICE***.  

### 7. Launch the SGE cluster
After the configuration is completed, it is very simple to launch the cluster.

```bash
pcluster create hpc-dcv
# Beginning cluster creation for cluster: hpc-dcv
# Creating stack named: parallelcluster-hpc-dcv
# Status: parallelcluster-hpc-dcv - CREATE_COMPLETE                               
# MasterPublicIP: 3.231.198.188
# ClusterUser: centos
# MasterPrivateIP: 172.31.64.54
```

It takes about 25 minutes to complete the cluster creation. 

Run "pcluster dcv connect hpc-dcv -k ~/.ssh/your-keypair.pem" to use DCV connect to the master node of the new cluster.   You will have a URL link to follow, ignoring the warning messages to proceed. 


At the master node, test to confirm:
+  Python, snakemake, perl and singularity have already been installed as expected.
+  The SGE cluster is ready to use: try *qhost*
![](./img/README_2020-04-02-16-27-26.png)


Below is a snaphsot of NICE DCV in use. 
![](./img/04.AWS_Cluster_Test1_2020-03-21-19-30-29.png)


### 8. Launch MoCCA-SV pipeline
We assume that you have followed [the instructions](https://github.com/NCI-CGR/MoCCA-SV) to prepare the input data, reference genome and configuration.   

There is one minor change to be made, as a newer version of snakemake is used here:
+ Insert the command line option ***' --core 4 '*** in the snakemake commands in /efs/MoCCA-SV/SV_wrapper.sh.
  
```bash
cmd=""
if [ "$clusterMode" == '"'"local"'"' ]; then
    cmd="conf=$configFile snakemake --cores 4 -p -s ${execDir}/Snakefile_SV_scaffold --use-singularity --singularity-args ${sing_arg} --rerun-incomplete &> ${logDir}/MoCCA-SV_${DATE}.out"
elif [ "$clusterMode" = '"'"unlock"'"' ]; then  # put in a convenience unlock
    cmd="conf=$configFile snakemake --cores 4 -p -s ${execDir}/Snakefile_SV_scaffold --unlock"
elif [ "$clusterMode" = '"'"dryrun"'"' ]; then  # put in a convenience dry run
    cmd="conf=$configFile snakemake --cores 4 -n -p -s ${execDir}/Snakefile_SV_scaffold"
else
    cmd="conf=$configFile snakemake --cores 4 -p -s ${execDir}/Snakefile_SV_scaffold --use-singularity --singularity-args ${sing_arg} --rerun-incomplete --cluster ${clusterMode} --jobs $numJobs --latency-wait ${latency} &> ${logDir}/MoCCA-SV_${DATE}.out"
    # --nt - keep temp files - can use while developing, especially for compare and annotate module.
fi
```

### Clean up
It is a good practice to clean up the work space after the project is completed. There are several things you may do:
+ Clean up the EFS space. In particular, remove the intermediate results, such as, .snakemake folders. 
+ Move the results to S3 folders.  
+ Delete the cluster. 

___
## Tips for trouble-shooting
It is unavoidable that you may run into some problems, no matter how good a tutorial is. :)

Here we have some tips for you:
+ Try to confirm your success in every step. 
+ Create the AWS ParallelCluster with *--norollback* option if there is something wrong in the bootstrapping.
  + Check the file ~/.parallelcluster/pcluster-cli.log at the login node.
  + ssh access to the master node and check the log files:
    + /var/log/cfn-init.log
    + /var/log/cloud-init.log
  
For example, 
```bash
pcluster create hpc --norollback
```
___
## Summary
+ AWS ParalleclCluster is a great solution to launch a scalable HPC in the cloud. 
  + In particular, I like the integration of EFS and NICE DCV in the cluster configuration. 
  + AWS ParalleclCluster not only support SGE (by default) but also support other schedulers, including AWS batch, slurm and torque. 
+ However, AWS ParallelCluster is not as a multi-platform HPC solution as [ElastiCluster](https://elasticluster.readthedocs.io/en/latest/).
+ Snakemake works with the SGE clsuter created by AWS ParallelCluster as well as the on-premise SGE cluster. 

