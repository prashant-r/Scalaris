#!/usr/bin/perl
if(@ARGV < 3) {
  print "usage: $0 [revision|HEAD] [de|tcp] Projectname \n";
  exit;
}
$rev = $ARGV[0];
$cl = $ARGV[1];
$name = $ARGV[2]."-".$cl."-".$rev."-".`date +%m%d%y%H%M%S`; 
chomp($name);
use Template;
my @Servers = (1,2,5,10,15);
my $resdir = `pwd`;
chomp($resdir);
$resdir.="/$name";
system "mkdir $resdir";
system "svn checkout -r $rev http://scalaris.googlecode.com/svn/trunk/ $resdir/scalaris-read-only";
#build scalairs
if($cl=="de") {
system "patch -p1  $resdir/scalaris-read-only/src/cs_send.erl <  $resdir/scalaris-read-only/contrib/using_distributed_erlang.patch";
}
system "cd  $resdir/scalaris-read-only/ ; ./configure";
system "cd  $resdir/scalaris-read-only/ ; make";
my $runfile= $resdir."/qsub.sh";
open(RUNFILE,">$runfile");
$resdir =~ s/NFS3/NFS4/g ;
foreach  my $s (@Servers) {
    my $tt = Template->new;
    $tt->process('bench_tt',  { server => $s , resdir => $resdir, cl => $cl , scalaris => $resdir."/scalaris-read-only/" },  $name."/bench_".$s."_run")
    		|| die $tt->error;
   print(RUNFILE "qsub bench_".$s."_run\n");
}

