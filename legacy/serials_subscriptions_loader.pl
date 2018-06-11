#!/usr/bin/perl
#---------------------------------
# Copyright 2012 ByWater Solutions
#
#---------------------------------
#
# -D Ruth Bavousett
# 
# Modification log: (initial and date)
#
#---------------------------------
#
# EXPECTS:
#   -4 serials export files from Voyager
#
# DOES:
#   -imports subscriptions and subscription history, if --update is set
#
# CREATES:
#   -component ID -> Koha serial subscription ID map, if --update is set
#
# REPORTS:
#   -what would be done, if --debug is set
#   -count of records read
#   -count of subscriptions added

use autodie;
use strict;
use warnings;
use Carp;
use Data::Dumper;
use English qw( -no_match_vars );
use Getopt::Long;
use Readonly;
use Text::CSV_XS;
use MARC::File::USMARC;
use MARC::Record;
use MARC::Batch;
use MARC::Charset;
use C4::Context;

local    $OUTPUT_AUTOFLUSH =  1;
Readonly my $NULL_STRING   => q{};
my $start_time             =  time();

my $debug   = 0;
my $doo_eet = 0;
my $i       = 0;
my $j       = 0;
my $k       = 0;
my $written = 0;
my $problem = 0;

my $input_filename        = $NULL_STRING;
my $mfhd_in_filename      = $NULL_STRING;
my $component_in_filename = $NULL_STRING;
my $subs_in_filename      = $NULL_STRING;
my $output_filename       = $NULL_STRING;
my $bib_map_filename   = $NULL_STRING;
my $branch_map_filename   = $NULL_STRING;
my $static_branch         = $NULL_STRING;

GetOptions(
    'view=s'      => \$input_filename,
    'mfhd=s'      => \$mfhd_in_filename,
    'component=s' => \$component_in_filename,
    'subs=s'      => \$subs_in_filename,
    'out=s'       => \$output_filename,
    'bib_map=s'   => \$bib_map_filename,
    'branch_map=s' => \$branch_map_filename,
    'static_branch=s' => \$static_branch,
    'debug'       => \$debug,
    'update'      => \$doo_eet,
);

for my $var ($input_filename,$mfhd_in_filename,$component_in_filename,$subs_in_filename,$output_filename,$bib_map_filename) {
   croak ("You're missing something") if $var eq $NULL_STRING;
}

print "Reading branch map...\n";
my %branch_map;
if ($branch_map_filename ne $NULL_STRING){
    my $csv = Text::CSV_XS->new();
    open my $mapfile,"<$branch_map_filename";
    while (my $row = $csv->getline($mapfile)){
        my @data = @$row;
        $branch_map{$data[0]} = $data[1];
    }
    close $mapfile;
}

print "Reading bib map...\n";
my %bib_map;
if ($bib_map_filename ne $NULL_STRING) {
   my $csv = Text::CSV_XS->new();
   open my $map_file,'<',$bib_map_filename;
   while (my $line = $csv->getline($map_file)) {
      my @data= @$line;
      $bib_map{$data[0]} = $data[1];
   }
   close $map_file;
}
print "Reading MFHD records...\n";
my %mfhd_data;
if ($mfhd_in_filename ne $NULL_STRING) {
   my $input_file = IO::File->new($mfhd_in_filename);
   my $batch      = MARC::Batch->new('USMARC',$input_file);
   $batch->warnings_off();
   $batch->strict_off();
MFHD:
   while() {
      my $record;
      eval {$record = $batch->next();};
      if ($@) {
         next MFHD;
      }
      last MFHD unless ($record);
      my $fld001 = $record->field('001');
      next MFHD unless ($fld001);
      my $mfhd_number = $fld001->data();
      my $location = $record->subfield('852','b');
      my $branch = $record->subfield('852','b');
      if ($static_branch ne $NULL_STRING) {
         $branch = $static_branch;
      }
      print "Kokoelma: $location\n";
      next MFHD unless ($branch);
      if (defined $branch_map{$branch}) {
         $branch = $branch_map{$branch};
      }
      print "Kirjasto: $branch\n";
      my $callnumber = $NULL_STRING;
      $callnumber = $record->subfield('852','h');
      my $holdings = '';
      my $missings = $NULL_STRING;
      my $coverage = $NULL_STRING;
      my $subscription_note = 'Migrated from Voyager. ';

MFHD_994:
      foreach my $field($record->field('994')) {
         # next MFHD_863 if ($field->indicator(2) ne '0');
         $subscription_note .= $field->subfield('a') . ' ';
         next MFHD_994;
      }



MFHD_863:
      foreach my $field($record->field('863')) {
         # next MFHD_863 if ($field->indicator(2) ne '0');
         $holdings .= $field->subfield('a') . ' ';
         $missings .= $field->subfield('z') . ' ';
         next MFHD_863;
      } 
MFHD_866:
      foreach my $field($record->field('866')) {
         # next MFHD_866 if ($field->indicator(2) ne '0');
         $coverage .= $field->subfield('a') . ' ';
         $coverage .= $field->subfield('z') . ' ';
         next MFHD_866;        
      }
      print "Holdings:$holdings\n";

      $mfhd_data{$mfhd_number}{'coverage'} = $coverage;       
      $mfhd_data{$mfhd_number}{'missings'} = $missings;
      $mfhd_data{$mfhd_number}{'callnumber'} = $callnumber;
      $mfhd_data{$mfhd_number}{'location'} = $location;
      $mfhd_data{$mfhd_number}{'branch'} = $branch;
      $mfhd_data{$mfhd_number}{'holdings'} = $holdings;
      $mfhd_data{$mfhd_number}{'subscription_note'} = $subscription_note;   

   }
}

print "Reading subscription records...\n";
my %sub_start_date;
if ($subs_in_filename ne $NULL_STRING) {
   my $csv = Text::CSV_XS->new();
   
open my $subs_file,'<:utf8',$subs_in_filename;
   $csv->column_names($csv->getline($subs_file));
SUBS:
   while (my $line = $csv->getline_hr($subs_file)) {
      $sub_start_date{$line->{SUBSCRIPTION_ID}} = _process_date($line->{START_DATE});
   }
   close $subs_file;
}

print "Reading component records...\n";
my %component_map;
if ($component_in_filename ne $NULL_STRING) {
   my $csv = Text::CSV_XS->new({binary => 1});
   open my $component_file,'<:utf8',$component_in_filename;
   $csv->column_names($csv->getline($component_file));
COMPONENT:
   while (my $line = $csv->getline_hr($component_file)) {
      $component_map{$line->{COMPONENT_ID}} = $line->{SUBSCRIPTION_ID};
   }
   close $component_file;
}
$debug and print Dumper(%component_map);

print "Processing view records...\n";
my $problem_2=0;
my $dbh=C4::Context->dbh();
my $sub_insert_sth = $dbh->prepare("INSERT INTO subscription
                                    (librarian,     branchcode, biblionumber,   notes, status,
                                     internalnotes, location,   aqbooksellerid, startdate, callnumber)
                                    VALUES (?,?,?,?,?,?,?,?,?,?)");
my $hist_insert_sth = $dbh->prepare("INSERT INTO subscriptionhistory
                                     (biblionumber, subscriptionid, recievedlist,librariannote,opacnote,missinglist)
                                     VALUES (?,?,?,?,?,?)");
my $csv=Text::CSV_XS->new({ binary => 1,sep_char =>"\t" });
open my $input_file,'<:utf8',$input_filename;
open my $output_file,'>',$output_filename;
$csv->column_names($csv->getline($input_file));
LINE:
while (my $line=$csv->getline_hr($input_file)) {
   $i++;
   print '.'    unless ($i % 10);
   print "\r$i" unless ($i % 100);

   my $biblionumber=$bib_map{$line->{BIB_ID}};
   if (!$biblionumber) {
      print "Biblio not found! $line->{BIB_ID}\n";
      $problem++;
      next LINE;
   }
   my $branchcode=$mfhd_data{$line->{MFHD_ID}}{'branch'};
   if (!exists $mfhd_data{$line->{MFHD_ID}}{'branch'}) {
       $branchcode = "UNKNOWN";
       print "Lopullinen pakoitettu sijaintikoodi $branchcode\n";
  }   

print "Lopullinen sijaintikoodi $branchcode\n";
my $holdings = $NULL_STRING;
  if (defined $mfhd_data{$line->{MFHD_ID}}{'holdings'}) {
         $holdings = $mfhd_data{$line->{MFHD_ID}}{'holdings'};
      } else {
	$holdings = "Tarkista data";
	}
   my $coverage =  $NULL_STRING;
  if (defined $mfhd_data{$line->{MFHD_ID}}{'coverage'}) {
         $coverage = $mfhd_data{$line->{MFHD_ID}}{'coverage'};
      } 
 
   my $missings = $mfhd_data{$line->{MFHD_ID}}{'missings'};
   my $callnumber = $mfhd_data{$line->{MFHD_ID}}{'callnumber'};
   my $location = $mfhd_data{$line->{MFHD_ID}}{'location'};
   my $internalnote = $line->{NOTE};
   my $subscription_note = 'Migrated from Voyager. '.$mfhd_data{$line->{MFHD_ID}}{'subscription_note'};
   print "Holding-tiedot $holdings\n";
   print "Huomautus $internalnote\n";
   next LINE if (!exists $component_map{ $line->{COMPONENT_ID} });
   my $startdate    = $sub_start_date{ $component_map{ $line->{COMPONENT_ID}}}; 
   if ($doo_eet) {
      $sub_insert_sth->execute('0', $branchcode, $biblionumber, undef, 1,
                               $internalnote, $location, undef, $startdate,$callnumber);
      my $subscription_id = $dbh->last_insert_id(undef, undef, undef, undef);
      if ($subscription_id) {
         $hist_insert_sth->execute($biblionumber, $subscription_id, $holdings, $subscription_note,$coverage,$missings);
         delete $component_map{ $line->{COMPONENT_ID}};
         print {$output_file} "$subscription_id,$line->{COMPONENT_ID}\n";
      }
      else {
         $problem_2++;
         next LINE;
      }
   $written++;
   }
}
close $input_file;
close $output_file;

print << "END_REPORT";

$i records read.
$written records written.
$problem records not loaded due to missing bibliographic records.
$problem_2 records not loaded due to failed INSERT in subscriptions table.
END_REPORT

my $end_time = time();
my $time     = $end_time - $start_time;
my $minutes  = int($time / 60);
my $seconds  = $time - ($minutes * 60);
my $hours    = int($minutes / 60);
$minutes    -= ($hours * 60);

printf "Finished in %dh:%dm:%ds.\n",$hours,$minutes,$seconds;

exit;

sub _process_date {
   my $datein = shift;
   return undef if !$datein;
   return undef if $datein eq "";
   return $datein;

}

