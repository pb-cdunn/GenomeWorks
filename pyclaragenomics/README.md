# pyclaragenomics

Python libraries and utilities for manipulating genomics data

## Installation

### Install from PyPI

A stable release of pyclaragenomics can be installed from PyPI. Currently only CUDA 10.0 and CUDA 10.1 based packages are supported.
Both of those packages are available for CPython 3.5 and 3.6.

```
pip install pyclaragenomics-cuda10-0
```

or 

```
pip install pyclaragenomics-cuda10-1
```

Details of the packages are available here -
- https://pypi.org/project/pyclaragenomics-cuda-10-0
- https://pypi.org/project/pyclaragenomics-cuda-10-1

### Testing installation

The following binaries should be on the `PATH` in order for the tests to pass:

* racon
* minimap2
* miniasm

To test the installation execute:

```
cd test/
python -m pytest
```

### Install from source
```
pip install -r requirements.txt
python setup_pyclaragenomics.py --build_output_folder BUILD_FOLDER
```

*Note* if you are developing pyclaragenomics you should do a develop build instead, changes you make to the source code will then be picked up on immediately:

```
pip install -r requirements.txt
python setup_pyclaragenomics.py --build_output_folder BUILD_FOLDER --develop
```

### Create a Wheel package

Use the following command in order to package pyclaragenomics into a wheel. (without installing)

```
pip install -r requirements.txt
python setup_pyclaragenomics.py --create_wheel_only
```

### Enable Doc Generation
`pyclaragenomics` documentation generation is managed through `Sphinx`.

NOTE: `pyclaragenomics` needs to be built completely in order for the
documentation to pick up docstrings for bindings.

```
pip install -r python-style-requirements.txt
./generate_docs
```

### Code Formatting

Clara Genomics Analysis follows the PEP-8 style guidelines for all its Python code. The automated
CI system for Clara Genomics Analysis run `flake8` to check the style.

To run style check manually, simply run the following from the top level folder.

```
pip install -r python-style-requirements.txt
./style_check
```

## Generating a simulated genome

A genome can be simulated without any parameters, to generate a 1Mbp reference with 20x coverage and median read length of 10kbp:

```
genome_simulator --snv_error_rate 0.01 --insertion_error_rate 0.005 --deletion_error_rate 0.005  --reference_length 1000000 --num_reads 2000 --median_read_length=10000
```

this will generate a 1Mbp reference genome with 20x coverage (default errors) reads in two files:

1. `ref.fasta` - the reference genome
2. `reads.fasta` - the corresponding reads

## Reporting assembly quality

`assembly_evaluation` reports on the assembly quality for GFA-format assemblies (e.g those generated by miniasm). It is a wrapper for the [Quast](https://github.com/ablab/quast) tool. This section assumes that we have reads and reference fasta files (e.g generated by `genome_simulator` as demonstrated in the above subsection).

### Step 1. Generate overlaps using minimap2

```
minimap2 -x ava-ont ./reads.fasta ./reads.fasta -t 12> out.paf
```

### Step 2. Assemble the overlaps
```
miniasm -f ./reads.fasta ./out.paf > reads.gfa
```

### Step 3. Evaluate assembly
```
assembly_evaluator --gfa_filepath ./reads.gfa --reference_filepath ./ref.fasta
```

This should produce the following output:

```
Assembly                     cca8d249_4adb_4dfc_b3eb_3fad6258851a
# contigs (>= 0 bp)          2
# contigs (>= 1000 bp)       2
# contigs (>= 5000 bp)       2
# contigs (>= 10000 bp)      2
# contigs (>= 25000 bp)      2
# contigs (>= 50000 bp)      2
Total length (>= 0 bp)       987753
Total length (>= 1000 bp)    987753
Total length (>= 5000 bp)    987753
Total length (>= 10000 bp)   987753
Total length (>= 25000 bp)   987753
Total length (>= 50000 bp)   987753
# contigs                    2
Largest contig               889670
Total length                 987753
Reference length             1000000
GC (%)                       55.64
Reference GC (%)             55.83
N50                          889670
NG50                         889670
N75                          889670
NG75                         889670
L50                          1
LG50                         1
L75                          1
LG75                         1
# misassemblies              0
# misassembled contigs       0
Misassembled contigs length  0
# local misassemblies        0
# scaffold gap ext. mis.     0
# scaffold gap loc. mis.     0
# unaligned mis. contigs     0
# unaligned contigs          0 + 0 part
Unaligned length             0
Genome fraction (%)          99.957
Duplication ratio            0.988
# N's per 100 kbp            0.00
# mismatches per 100 kbp     1010.43
# indels per 100 kbp         1801.27
Largest alignment            889670
Total aligned length         987753
NA50                         889670
NGA50                        889670
NA75                         889670
NGA75                        889670
LA50                         1
LGA50                        1
LA75                         1
LGA75                        1
```
The error rate is calculated by
```math
\text{error rate} = \frac{\text{mismatches per 100 kbp} + \text{indels per 100 kbp}} {10^5} 
```
The above result indicates a total error rate of ~2.8%.

### Step 4 (optional). Polish with racon and re-evaluate

1. Convert the GFA to a FA file:

```
awk '/^S/{print ">"$2"\n"$3}' reads.gfa | fold > assembly.fa
```

2. map the reads to the assembly

```
minimap2 assembly.fa reads.fasta > overlaps.paf
```

3. Polish the assembly with Racon

```
racon -c4 -m 8 -x -6 -g -8 -w 500 -t 12 -q -1 reads.fasta overlaps.paf assembly.fa > polished_assembly.fa
```

4. Analyse with Quast:

```
quast.py polished_assembly.fa -r ./ref.fasta
```

5. Looking at the report file (`less ./quast_results/latest/report.txt`) should show results similar to this:


```
Assembly                     polished_assembly
# contigs (>= 0 bp)          2
# contigs (>= 1000 bp)       2
# contigs (>= 5000 bp)       2
# contigs (>= 10000 bp)      2
# contigs (>= 25000 bp)      2
# contigs (>= 50000 bp)      2
Total length (>= 0 bp)       990107
Total length (>= 1000 bp)    990107
Total length (>= 5000 bp)    990107
Total length (>= 10000 bp)   990107
Total length (>= 25000 bp)   990107
Total length (>= 50000 bp)   990107
# contigs                    2
Largest contig               891746
Total length                 990107
Reference length             1000000
GC (%)                       55.76
Reference GC (%)             55.83
N50                          891746
NG50                         891746
N75                          891746
NG75                         891746
L50                          1
LG50                         1
L75                          1
LG75                         1
# misassemblies              0
# misassembled contigs       0
Misassembled contigs length  0
# local misassemblies        0
# scaffold gap ext. mis.     0
# scaffold gap loc. mis.     0
# unaligned mis. contigs     0
# unaligned contigs          0 + 0 part
Unaligned length             0
Genome fraction (%)          99.956
Duplication ratio            0.991
# N's per 100 kbp            0.00
# mismatches per 100 kbp     2.00
# indels per 100 kbp         913.50
Largest alignment            891746
Total aligned length         990107
NA50                         891746
NGA50                        891746
NA75                         891746
NGA75                        891746
LA50                         1
LGA50                        1
LA75                         1
LGA75                        1
```

Total error rate has dropped from 2.8% to 0.9%. Most of the remaining error is in indels.