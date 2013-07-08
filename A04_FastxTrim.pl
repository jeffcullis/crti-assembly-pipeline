#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use YAML::XS qw(DumpFile LoadFile);

my $options = {};
my $qsub_bin = "/opt/gridengine/bin/lx26-amd64/qsub";
my $fastx_trimmer_bin = "/opt/bio/fastx/bin/fastx_trimmer";
my @qsub_cmd_list = ();
my @html_lines = ();
my $records = {};

sub check_opts
{
    unless ($options->{yaml_in} and $options->{yaml_out}) {
        die "Usage: $0 -i <yaml input file> -o <yaml output file> 
            Optional args:
            	--sample <sample id>
                --verbose
                --testing
                --qsub_opts <qsub options>
                --qsub_script <qsub script name>
                --qsub_batch_file
                --run_fastx
                ";
    }
}

sub gather_opts
{
    GetOptions($options,
            'yaml_in|i=s',
            'yaml_out|o=s',
            'trim_params_table|t=s',
            'notrim_report|r=s',
            'verbose|v',
            'testing',
            'qsub_opts=s',
            'qsub_script=s',
            'qsub_batch_file=s',
            'run_fastx',
            );
    check_opts;
}

sub get_subrecord
{
    my $rec = shift;
    my $kref = shift;
    my @keylist = @$kref;
    my $ref = $rec;
    for my $keyname (@keylist) {
        if (defined $ref->{$keyname}) {
            $ref = $ref->{$keyname};
        } else {
            return '';
        }
    }
    return $ref;
}

sub parse_trim_params
{
    my $ft = ($options->{trim_params_table} ? $options->{trim_params_table} : '');
    if (-e $ft) {
        open (FTRIM, '<', $ft) or die "Error: could not open trim params file $ft\n";
        <FTRIM>; # Skip header 1st line
        while (my $line = <FTRIM>) {
            chomp $line;
            my ($sample, $type, $direction, $Qval, $fval) = split(/\s+/, $line);
            if ($sample =~ /[A-Z][a-z]_(S00[A-Z0-9]+)/) {
                $sample = $1;
            }
            if (defined $records->{$sample}) {
                print "Found valid sample $sample\n";
                my $rec = $records->{$sample};
                unless (defined $rec->{fastx_trimmer}) { $rec->{fastx_trimmer} = {}; }
                $rec->{fastx_trimmer}->{$direction} = {};
                print "fastx timer $direction $fval $Qval\n";
                $rec->{fastx_trimmer}->{$direction}->{fval} = $fval;
                $rec->{fastx_trimmer}->{$direction}->{Qval} = $Qval;
            }
        }
    } else {
        die "Error: couldn't parse trim params file $ft\n";
    }
}

sub get_trim_cmd
{
    my $rec = shift;
    my $direction = shift;
    my $rawfile = $rec->{$direction}->{rawdata_symlink};
    my $outfile = $rec->{$direction}->{trimdata};
    my $Qval = $rec->{fastx_trimmer}->{$direction}->{Qval};
    my $fval = $rec->{fastx_trimmer}->{$direction}->{fval};
    my $cmd = $fastx_trimmer_bin . " -Q $Qval -f $fval -i $rawfile -o $outfile";
    $rec->{fastx_trimmer}->{$direction}->{trim_cmd} = $cmd;
    return $cmd;
}

sub get_qsub_cmd
{
    my $rec = shift;
    my $direction = shift;
    my $trim_cmd = $rec->{fastx_trimmer}->{$direction}->{trim_cmd};
    my $qsub_cmd = $qsub_bin;
    if ($options->{qsub_opts}) {
        $qsub_cmd .= " " . $options->{qsub_opts};
    }
    if ($options->{qsub_script}) {
        $qsub_cmd .= " " . $options->{qsub_script};
    }
    $qsub_cmd .= " '" . $trim_cmd . "'";
    $rec->{fastx_trimmer}->{$direction}->{qsub_cmd} = $qsub_cmd;
    return $qsub_cmd;
}

# For each record, generate the trimmed output filename from params
# If output filename doesn't exist, generate the fastx_trimmer command
sub apply_trim_params
{
    foreach my $sample (keys %{$records}) {
        my $rec = $records->{$sample};
        if (defined $rec->{fastx_trimmer}) {
            foreach my $direction (qw(R1 R2)) {
                my $fval = get_subrecord($rec, ['fastx_trimmer', $direction, 'fval']);
                my $Qval = get_subrecord($rec, ['fastx_trimmer', $direction, 'Qval']);
                if ($fval and $Qval) {
                    #my $fval = $rec->{fastx_trimmer}->{$direction}->{fval};
                    #my $Qval = $rec->{fastx_trimmer}->{$direction}->{Qval};
                    my $rawfile = $rec->{$direction}->{rawdata_symlink};
                    my $trimfile = '';
                    if ($rawfile =~ /(.*)_(R[12].fq)/) {
                        $trimfile = $1 . "_trim_" . $fval . "-0-0_" . $2;
                        $rec->{$direction}->{trimdata} = $trimfile;
                    } else {
                        die "Error: raw file $rawfile cannot be used to get a trim file. Aborting";
                    }
                    if (-e $trimfile) {
                        if ($options->{verbose}) {
                            print "Trimmed file $trimfile already exists\n";
                        }
                    } else {
                        my $trim_cmd = get_trim_cmd($rec, $direction);
                        my $qsub_cmd = get_qsub_cmd($rec, $direction);
                        push (@qsub_cmd_list, $qsub_cmd);
                    }
                } else {
                    print "Error: found fastx_trimmer record for $sample $direction but fval and qval are undefined!\n";
                }
            }
        } elsif ($options->{notrim_report}) {
            for my $direction (qw(R1 R2)) {
                #my $html_report = $rec->{fastqc}->{$direction}->{raw_report_html};
                my $html_report = get_subrecord($rec, ['fastqc', $direction, 'raw_report_html']);
                if ($html_report) {
                    push (@html_lines, "<tr><td>$sample</td><td>$direction</td><td><a href='${html_report}'>report</a></td></tr>");
                } else {
                    print "Warning: no raw fastqc_report.html file specified for sample $sample, direction $direction\n";
                }
            }
        }
    }           
}

# Gather reports into output html file for
# any raw files we find that have no trimmed counterpart.
sub report_notrim
{
    my $outfile = $options->{notrim_report};
    open (FREP, '>', $outfile) or die "Error: could not open file $outfile\n";
    print FREP "<html><body><table>\n";
    print FREP join("\n", @html_lines) . "\n";
    print FREP "</table></body></html>";
    close (FREP);
}
                    
sub write_batch
{
    my $fb = $options->{qsub_batch_file};
    open (FBATCH, '>', $fb) or die "Error: couldn't open file $fb\n";
    print FBATCH join("\n", @qsub_cmd_list) . "\n";
    close (FBATCH);
}


gather_opts;
$records = LoadFile($options->{yaml_in});
if ($options->{trim_params_table}) {
    parse_trim_params;
}
apply_trim_params;
if ($options->{notrim_report}) {
    report_notrim
}
if ($options->{qsub_batch_file}) {
    write_batch;
}
DumpFile($options->{yaml_out}, $records);














