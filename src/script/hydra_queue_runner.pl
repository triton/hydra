#! /var/run/current-system/sw/bin/perl -w

use strict;
use Cwd;
use File::Basename;
use POSIX qw(dup2 :sys_wait_h);
use Hydra::Schema;
use Hydra::Helper::Nix;


chdir getHydraPath or die;
my $db = openHydraDB;

my $hydraHome = $ENV{"HYDRA_HOME"};
die "The HYDRA_HOME environment variable is not set!\n" unless defined $hydraHome;

#$SIG{CHLD} = 'IGNORE';


sub unlockDeadBuilds {
    # Unlock builds whose building process has died.
    $db->txn_do(sub {
        my @builds = $db->resultset('Builds')->search(
            {finished => 0, busy => 1}, {join => 'schedulingInfo'});
        foreach my $build (@builds) {
            my $pid = $build->schedulingInfo->locker;
            my $unlock = 0;
            if ($pid == $$) {
                # Work around sqlite locking timeouts: if the child
                # barfed because of a locked DB before updating the
                # `locker' field, then `locker' is still set to $$.
                # So if after a minute it hasn't been updated,
                # unlock the build.  !!! need a better fix for those
                # locking timeouts.
                if ($build->schedulingInfo->starttime + 60 < time) {
                    $unlock = 1;
                }
            } elsif (kill(0, $pid) != 1) { # see if we can signal the process
                $unlock = 1;
            }
            if ($unlock) {
                print "build ", $build->id, " pid $pid died, unlocking\n";
                $build->schedulingInfo->busy(0);
                $build->schedulingInfo->locker("");
                $build->schedulingInfo->update;
            }
        }
    });
}


sub checkBuilds {
    print "looking for runnable builds...\n";

    my @buildsStarted;

    $db->txn_do(sub {

        # Get the system types for the runnable builds.
        my @systemTypes = $db->resultset('Builds')->search(
            { finished => 0, busy => 0, enabled => 1, disabled => 0 },
            { join => ['schedulingInfo', 'project'], select => [{distinct => 'system'}], as => ['system'] });

        # For each system type, select up to the maximum number of
        # concurrent build for that system type.  Choose the highest
        # priority builds first, then the oldest builds.
        foreach my $system (@systemTypes) {
            # How many builds are already currently executing for this
            # system type?
            my $nrActive = $db->resultset('Builds')->search(
                {finished => 0, busy => 1, system => $system->system},
                {join => 'schedulingInfo'})->count;

            # How many extra builds can we start?
            (my $systemTypeInfo) = $db->resultset('SystemTypes')->search({system => $system->system});
            my $maxConcurrent = defined $systemTypeInfo ? $systemTypeInfo->maxconcurrent : 2;
            my $extraAllowed = $maxConcurrent - $nrActive;
            $extraAllowed = 0 if $extraAllowed < 0;

            # Select the highest-priority builds to start.
            my @builds = $extraAllowed == 0 ? () : $db->resultset('Builds')->search(
                { finished => 0, busy => 0, system => $system->system, enabled => 1, disabled => 0 },
                { join => ['schedulingInfo', 'project'], order_by => ["priority DESC", "timestamp"],
                  rows => $extraAllowed });

            print "system type `", $system->system,
                "': $nrActive active, $maxConcurrent allowed, ",
                "starting ", scalar(@builds), " builds\n";

            foreach my $build (@builds) {
                my $logfile = getcwd . "/logs/" . $build->id;
                mkdir(dirname $logfile);
                unlink($logfile);
                $build->schedulingInfo->busy(1);
                $build->schedulingInfo->locker($$);
                $build->schedulingInfo->logfile($logfile);
                $build->schedulingInfo->starttime(time);
                $build->schedulingInfo->update;
                push @buildsStarted, $build;
            }
        }
    });

    # Actually start the builds we just selected.  We need to do this
    # outside the transaction in case it aborts or something.
    foreach my $build (@buildsStarted) {
        my $id = $build->id;
        print "starting build $id (", $build->project->name, ":", $build->jobset->name, ':', $build->job->name, ") on ", $build->system, "\n";
        eval {
            my $logfile = $build->schedulingInfo->logfile;
            my $child = fork();
            die unless defined $child;
            if ($child == 0) {
                eval {
                    open LOG, ">$logfile" or die "cannot create logfile $logfile";
                    POSIX::dup2(fileno(LOG), 1) or die;
                    POSIX::dup2(fileno(LOG), 2) or die;
                    exec("hydra_build.pl", $id);
                };
                warn "cannot start build $id: $@";
                POSIX::_exit(1);
            }
        };
        if ($@) {
            warn $@;
            $db->txn_do(sub {
                $build->schedulingInfo->busy(0);
                $build->schedulingInfo->locker($$);
                $build->schedulingInfo->update;
            });
        }
    }
}


if (scalar(@ARGV) == 1 && $ARGV[0] eq "--unlock") {
    unlockDeadBuilds;
    exit 0;
}


while (1) {
    eval {
        # Clean up zombies.
        while ((waitpid(-1, &WNOHANG)) > 0) { };
        
        unlockDeadBuilds;
        
        checkBuilds;
    };
    warn $@ if $@;

    print "sleeping...\n";
    sleep(5);
}