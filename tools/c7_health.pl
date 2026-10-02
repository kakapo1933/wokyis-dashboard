#!/usr/bin/perl
# c7_health.pl FROM TO [HEALTH_TSV] < panel log(s) — HEALTH statistics for one measured window (tools/c7_measure.sh).
#   FROM / TO: local wall clock "YYYY-MM-DDTHH:MM:SS" (the log's own basis; the UTC offset is ignored).
#   Points: the last `HEALTH cpu_s=…` line at or before FROM (≤ 65 s before: the baseline that closes the warm-up
#   minute) + every one in (FROM, TO + 2 s].
#   health_max5 = max over pairs (i, j), t_j − t_i ≥ 295 s, i the latest such point, of (cpu_s_j − cpu_s_i) / (t_j − t_i)
#   × 100 (% of one core: HEALTH cpu_s = the panel process + its reaped children, proc_pid_rusage ri_child_*); "-"
#   when the window is shorter. passes_per_s = Σ passes (or v1 draws)
#   after the first point / span; draw_ms_avg = mean; mem_hz / view = distinct values; sys_dur_us_p99 = max.
# Prints one line: max5 \t passes_per_s \t draw_ms_avg \t mem_hz \t sys_dur_us_p99 \t view \t points
# HEALTH_TSV (optional): per point t, wall, cpu_s, passes, draw_ms_avg, mem_hz, view, occluded, win5_pct.
#   t = local wall-clock seconds read with timegm (not a real epoch: + the UTC offset); only differences are used.
use strict; use warnings; use Time::Local;
my ($from, $to, $tsv) = @ARGV;
die "usage: c7_health.pl FROM TO [TSV] < log\n" unless defined $to;
sub ts { my ($s) = @_; my ($Y,$M,$D,$h,$m,$sec) = $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d(?:\.\d+)?)/ or return undef;
         return timegm(0, $m, $h, $D, $M - 1, $Y) + $sec; }
my ($f, $t) = (ts($from), ts($to));
die "bad FROM/TO\n" unless defined $f && defined $t;
my (@all);
while (my $l = <STDIN>) {
    next unless $l =~ / HEALTH .*\bcpu_s=([0-9.]+)/;
    my $cpu = $1; my $tt = ts($l); next unless defined $tt;
    my %kv = $l =~ /\b([a-z_0-9]+)=(\S+)/g;
    push @all, { t => $tt, wall => substr($l, 0, 23), cpu => $cpu, passes => $kv{passes} // $kv{draws} // '-',
                 draw => $kv{draw_ms_avg} // '-', memhz => $kv{mem_hz} // '-', view => $kv{view} // '-',
                 occ => $kv{occluded} // '-', p99 => $kv{sys_dur_us_p99} // '-' };
}
@all = sort { $a->{t} <=> $b->{t} } @all;
my @p; my $base;
for my $x (@all) { $base = $x if $x->{t} <= $f && $f - $x->{t} <= 65; }
push @p, $base if $base;
push @p, grep { $_->{t} > $f && $_->{t} <= $t + 2 } @all;
my $max5;
for my $j (0 .. $#p) {
    my $i;
    for my $k (0 .. $j - 1) { $i = $k if $p[$j]{t} - $p[$k]{t} >= 295; }
    next unless defined $i;
    my $pct = ($p[$j]{cpu} - $p[$i]{cpu}) / ($p[$j]{t} - $p[$i]{t}) * 100;
    $p[$j]{win} = sprintf('%.3f', $pct);
    $max5 = $pct if !defined $max5 || $pct > $max5;
}
my @after = @p[1 .. $#p];   # p[0] (the baseline) closes the interval before the window
my ($pass, $draw, $p99) = ('-', '-', '-');
if (@p >= 2) {
    my ($sum, $ok) = (0, 1);
    for (@after) { if ($_->{passes} =~ /^\d+$/) { $sum += $_->{passes} } else { $ok = 0 } }
    my $span = $p[-1]{t} - $p[0]{t};
    $pass = sprintf('%.2f', $sum / $span) if $ok && $span > 0;
}
my @d = grep { /^[0-9.]+$/ } map { $_->{draw} } @after;
$draw = sprintf('%.3f', (eval { my $s = 0; $s += $_ for @d; $s }) / @d) if @d;
my @q = grep { /^\d+$/ } map { $_->{p99} } @after;
if (@q) { $p99 = (sort { $b <=> $a } @q)[0]; }
my %seen; my @mh = grep { !$seen{"m$_"}++ } map { $_->{memhz} } @after;
my @vw = grep { !$seen{"v$_"}++ } map { $_->{view} } @after;
if (defined $tsv) {
    open my $o, '>', $tsv or die "$tsv: $!\n";
    print $o "t\twall\tcpu_s\tpasses\tdraw_ms_avg\tmem_hz\tview\toccluded\twin5_pct\n";
    printf $o "%.3f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $_->{t}, $_->{wall}, $_->{cpu}, $_->{passes}, $_->{draw}, $_->{memhz},
        $_->{view}, $_->{occ}, $_->{win} // '-' for @p;
    close $o;
}
printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\n", defined $max5 ? sprintf('%.3f', $max5) : '-', $pass, $draw,
    (@mh ? join(',', @mh) : '-'), $p99, (@vw ? join(',', @vw) : '-'), scalar @p;
