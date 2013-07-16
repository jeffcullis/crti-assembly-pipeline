#!/usr/bin/env perl
use strict;
use warnings;
use YAML::XS qw(LoadFile DumpFile);
use File::Path;
use Getopt::Long;

# From the records, pull just the genomic data
# Read in genome lengths from file
# Write out all the velveth/g commands per sample per kmer

# Ideally: have separate folders within velvet that include
# e.g. the different genome lengths, QC trims etc. that we try?

my $options = {};
my $records = {};
my @genomic_samples = ();
my @glen_col_headers = qw(IL_Species IL_Genotype IL_Biomaterial IL_Biomaterial_type 
    IL_Sample_ID IL_Kingdom IL_Resident_Expert RG_Species RG_Strain RG_Est_Genome_Length
     RG_Source RG_Citation RG_URL RG_Notes);

my $tr;
my $trdata;
my $velvet_bin_dir = "/opt/bio/velvet";
my @kbins = (0, 31, 63, 127, 145); 
# @ kbins is only used by get_kmer_bin function below.
# Assumes we have binaries of form
# velvetg_x and velveth_x for x>0 and x in @kbins.

sub set_default_opts
{
    my %defaults = qw(
            yaml_in yaml_files/05_readinfo.yml
            yaml_out yaml_files/06_velvet.yml
            min_kmer 21 
            max_kmer 95
            trim 1
            genome_length_file input_data/GenomeLengthEst.tab
            );
    for my $key (keys %defaults) {
        $options->{$key} = $defaults{$key} unless $options->{$key};
    }
    if ($options->{raw}) {
        $tr = "raw";
        $trdata = "rawdata";
    } else {
        $tr = "trim";
        $trdata = "trimdata";
    }
}

sub check_opts
{
    unless ($options->{yaml_in} and $options->{yaml_out}) {
        die "Usage: $0 -i <yaml input file> -o <yaml output file>
            Optional:
                --genome_length_file <filename>
                --trim
                --raw
                --submit
                --verbose
                --min_kmer <value (default 21)>
                --max_kmer <value (default 95)>
                --vh_batch_file <filename>
                --vg_batch_file <filename>
                ";
    }
}


sub gather_opts
{
    GetOptions($options,
            'yaml_in|i=s',
            'yaml_out|o=s',
            'genome_length_file|g=s',
            'trim',
            'raw',
            'submit',
            'verbose',
            'min_kmer',
            'max_kmer',
            'vh_batch_file=s',
            'vg_batch_file=s',
            );
    set_default_opts;
    check_opts;
}

sub parse_genome_lengths
{
    my $fname = ($options->{genome_length_file} ? $options->{genome_length_file} : '');
    if ($fname) {
        open (FGLEN, '<', $fname) or die "Error: couldn't open file $fname\n";
        <FGLEN>; <FGLEN>; # Skip first two col header lines.
        while (my $line = <FGLEN>) {
            chomp $line;
            my @fields = split(/\t/, $line);
            my %fh = map { $glen_col_headers[$_] => ($fields[$_] ? $fields[$_] : '') } (0..$#glen_col_headers);
            my $sample = $fh{IL_Sample_ID};
            $sample =~ s/\s+//g;
            my $rec = ($records->{$sample} ? $records->{$sample} : '');
            if ($rec) {
                $rec->{related_genome_length} = {};
                my $rgl_ref = $rec->{related_genome_length};
                for my $ch (@glen_col_headers) {
                    if ($ch =~ /^RG/) {
                        $rgl_ref->{$ch} = $fh{$ch};
                    }
                }
            } else {
                print "Warning: in file $fname, sample $sample was not found in input yaml file.\n";
            }
        }
        close (FGLEN);
    }
}

sub get_genomic_records
{
    for my $sample (keys %$records) {
        if ($records->{$sample}->{bio_type} =~ /DNA/) {
            push (@genomic_samples, $sample);
        }
    }
}

sub get_check_record
{
    my $ref = shift;
    my $kref = shift;
    for my $key (@$kref) {
        if (defined ($ref->{$key})) {
            $ref = $ref->{$key};
        } else {
            return '';
        }
    }
    return $ref;
}

sub get_coverage_vars
{
    my $rec = shift;
    print "Getting cov vars for " . $rec->{sample} . "\n";
    my $var = {};
    $var->{R1_nreads} = get_check_record($rec, ["data_stats", "R1", $trdata, "num_reads"]);
    $var->{R1_readlen} = get_check_record($rec, ["data_stats", "R1", $trdata, "read_length"]);
    $var->{R2_nreads} = get_check_record($rec, ["data_stats", "R2", $trdata, "num_reads"]);
    $var->{R2_readlen} = get_check_record($rec, ["data_stats", "R2", $trdata, "read_length"]);
    $var->{genome_length} = get_check_record($rec, ["related_genome_length", "RG_Est_Genome_Length"]);
    my $pass = 1;
    for my $key (keys %$var) {
        if ($var->{$key} !~ /^\s*\d+\s*$/) {
            print "Got bad var " . $var->{$key} . " at key " . $key . "\n";
            $pass = 0;
        }
    }
    if ($pass) {
        $var->{total_coverage} = ($var->{R1_nreads} * $var->{R1_readlen} + $var->{R2_nreads} * $var->{R2_readlen}) / $var->{genome_length};
        $var->{avg_readlen} = ($var->{R1_readlen} + $var->{R2_readlen}) / 2;
        $rec->{velvet}->{total_coverage} = $var->{total_coverage};
        $rec->{velvet}->{average_read_length} = $var->{avg_readlen};
        return $var;
    } else {
        return '';
    }
}

sub calc_exp_cov
{
    my $var = shift;
    my $kmer = shift;
    my $exp_cov_float = $var->{total_coverage} * ($var->{avg_readlen} - $kmer + 1) / $var->{avg_readlen};
    my $exp_cov_rounded_int = int($exp_cov_float + 0.5);
    return $exp_cov_rounded_int;
} 

sub get_assembly_outdir
{
    my $rec = shift;
    unless (defined ($rec->{velvet})) {
        $rec->{velvet} = {};
    }
    unless (defined ($rec->{velvet}->{$tr})) {
        $rec->{velvet}->{$tr} = {};
    }
    my $assembly_outdir = $rec->{sample_dir} . "/assemblies/velvet/$tr";
    mkpath $assembly_outdir;
    $rec->{velvet}->{$tr}->{assembly_outdir} = $assembly_outdir;
    return $assembly_outdir;
}

sub get_velvet_kdir
{
    my $assembly_outdir = shift;
    my $kmer = shift;
    my $exp_cov = shift;
    my $kdir = $assembly_outdir . "/assem_kmer-" . $kmer . "_exp-" . $exp_cov . "_covcutoff-auto";
    mkpath $kdir;
    return $kdir;
}

sub get_kmer_bin
{
    my $kmer = shift;
    my $bin = '';
    if ($kmer < $kbins[0]) { 
        print "Error: kmer value $kmer must be a positive integer!\n";
    } elsif ($kmer > $kbins[$#kbins]) {
        print "kmer value $kmer not supported. Recompile velvet for higher kmer.\n";
    } else {
        for (my $i = 0; $i < $#kbins; $i++) {
            if ($kbins[$i] < $kmer and $kmer <= $kbins[$i+1]) {
                $bin = $kbins[$i+1];
            }
        }
    }
    return $bin;
}
    

sub get_velveth_cmd
{
    my $rec = shift;
    my $kmer = shift;
    my $kmer_bin = shift;
    my $outdir = shift;
    my $velveth_bin = $velvet_bin_dir . "/velveth_" . $kmer_bin;
    my $r1_file = $rec->{R1}->{$trdata};
    my $r2_file = $rec->{R2}->{$trdata};
    my $velveth_cmd = $velveth_bin . " " . $outdir . " " . $kmer . 
        "  -fastq -shortPaired -create_binary -separate " . $r1_file . " " . $r2_file;
    $rec->{velveth}->{$tr}->{cmd} = {} unless ($rec->{velveth}->{$tr}->{cmd});
    $rec->{velveth}->{$tr}->{cmd}->{$kmer} = $velveth_cmd;
    return $velveth_cmd;
}

sub get_velvetg_cmd
{
    my $rec = shift;
    my $exp_cov = shift;
    my $kmer = shift;
    my $kmer_bin = shift;
    my $working_dir = shift;
    my $min_contig_opt = " ";
    my $scaffolding_opt = " -scaffolding yes ";
    my $velvetg_bin = $velvet_bin_dir . "/velvetg_" . $kmer_bin;
    my $velvetg_cmd = $velvetg_bin . " " . $working_dir . " " .
        "-ins_length 300 -exp_cov " . $exp_cov . " " . $min_contig_opt . 
        $scaffolding_opt . " -amos_file no -cov_cutoff auto";
    $rec->{velvetg}->{$tr}->{cmd} = {} unless ($rec->{velvetg}->{$tr}->{cmd});
    $rec->{velvetg}->{$tr}->{cmd}->{$kmer} = $velvetg_cmd;
    return $velvetg_cmd;
}

# keep a list of our common output dirs for each kmer of velvet assembly
sub track_kmer_dirs
{
    my $rec = shift;
    my $kmer = shift;
    my $kmer_dir = shift;
    $rec->{velvet}->{$tr}->{kmer_dirs} = {} unless ($rec->{velvet}->{$tr}->{kmer_dirs});
    $rec->{velvet}->{$tr}->{kmer_dirs}->{$kmer} = $kmer_dir;
}

sub get_velvet_cmds
{
    my $rec = shift;
    my $cov_vars = shift;
    my $assembly_outdir = shift;
    my $kmer = shift;
    my $kmer_bin = get_kmer_bin($kmer);
    my $exp_cov = calc_exp_cov($cov_vars, $kmer);
    my $kdir = get_velvet_kdir($assembly_outdir, $kmer, $exp_cov);
    track_kmer_dirs($rec, $kmer, $kdir);
    my $vh_cmd = get_velveth_cmd($rec, $kmer, $kmer_bin, $kdir);
    my $vg_cmd = get_velvetg_cmd($rec, $exp_cov, $kmer, $kmer_bin, $kdir);
    return ($vh_cmd, $vg_cmd);
}

sub init_velvet_recs
{
    my $rec = shift;
    for my $key (qw(velvet velveth velvetg)) {
        $rec->{$key} = {} unless ($rec->{$key});
        $rec->{$key}->{$tr} = {} unless ($rec->{$key}->{$tr});
    }
    $rec->{velvet}->{$tr}->{min_kmer} = $options->{min_kmer};
    $rec->{velvet}->{$tr}->{max_kmer} = $options->{max_kmer};
}

sub build_assembly_cmds
{
    for my $sample (@genomic_samples) {
        my $rec = ($records->{$sample} ? $records->{$sample} : '');
        unless (defined($rec)) { die "Couldn't get a record from yaml file for sample $sample.\n"; }
        init_velvet_recs($rec);
        my $cov_vars = get_coverage_vars($rec);
        if ($cov_vars) {
            my $assembly_outdir = get_assembly_outdir($rec);
            for (my $kmer =$options->{min_kmer}; $kmer <= $options->{max_kmer}; $kmer = $kmer+2) {
                my ($vh_cmd, $vg_cmd) = get_velvet_cmds($rec, $cov_vars, $assembly_outdir, $kmer);
            }
        } else {
            print "Warning: Couldn't parse coverage vars from input sample $sample.\n";
        }
    }
}

gather_opts;
$records = LoadFile($options->{yaml_in});
get_genomic_records;
parse_genome_lengths;
build_assembly_cmds;
DumpFile($options->{yaml_out}, $records);