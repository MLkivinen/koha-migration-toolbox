#!/usr/bin/perl
#---------------------------------
# Copyright 2011 ByWater Solutions
#
#---------------------------------
#
# -D Ruth Bavousett
#
#---------------------------------

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use Text::CSV;
use C4::Context;
use C4::Items;
$|=1;
my $debug=0;
my $doo_eet=0;

my $infile_name = "";

GetOptions(
    'in=s'            => \$infile_name,
    'debug'           => \$debug,
    'update'          => \$doo_eet,
);

if (($infile_name eq '') ){
  print "Something's missing.\n";
  exit;
}

my $csv = Text::CSV->new();
open my $in,"<$infile_name";
my $i=0;
my $j=0;
my $problem=0;
my $dbh = C4::Context->dbh();
my $item_sth = $dbh->prepare("SELECT itemnumber FROM items WHERE barcode=?");
my $thisborrowerbar = "";
my $thisborrower;
RECORD:
while (my $line = $csv->getline($in)) {
   my @data = @$line;
   $i++;
   print ".";
   print "\r$i" unless $i % 100;

   next RECORD if (($data[0] eq q{}) || ($data[1] == 1));

   my $thisitembar = $data[0];
   $item_sth->execute($thisitembar);
   my $hash=$item_sth->fetchrow_hashref();
   my $thisitem = $hash->{'itemnumber'};
  
   if ($thisitem){
      $j++;
      $debug and print "I:$thisitembar S:$data[1]\n";
      if ($doo_eet){
         if ($data[1] == 12){
            C4::Items::ModItem({itemlost  => 4 },undef,$thisitem);
         }
         if ($data[1] == 13){
            C4::Items::ModItem({itemlost  => 1 },undef,$thisitem);
         }
         if ($data[1] == 14){
            C4::Items::ModItem({itemlost  => 2 },undef,$thisitem);
         }
         if ($data[1] == 16){
            C4::Items::ModItem({damaged   => 1 },undef,$thisitem);
         }
         if ($data[1] == 17){
            C4::Items::ModItem({wthdrawn  => 1 },undef,$thisitem);
         }
      }
   }
   else{
      print "\nProblem record:\n";
      print "I:$thisitembar ($thisitem) S:$data[1]\n";
      $problem++;
   }
   last if ($debug && $j>20);
   next;
}

close $in;

print "\n\n$i lines read.\n$j items modified.\n$problem problem lines.\n";
exit;
