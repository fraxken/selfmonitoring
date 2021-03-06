# use dependencies
use strict;
use warnings;
use lib "D:/apps/Nimsoft/perllib";
use lib "D:/apps/Nimsoft/Perl64/lib/Win32API";
use Data::Dumper;
use Nimbus::API;
use Nimbus::CFG;
use Nimbus::PDS;
use perluim::log;
use perluim::main;
use perluim::alarmsmanager;
use perluim::utils;
use perluim::filereader;
use perluim::dtsrvjob;
use perluim::filemap;
use POSIX qw( strftime );
use Time::Piece;

#
# Declare default script variables & declare log class.
#
my $time = time();
my $version = "1.5.1";
my ($Console,$SDK,$Execution_Date,$Final_directory);
$Execution_Date = perluim::utils::getDate();
$Console = new perluim::log('selfmonitoring.log',5,0,'yes');

# Handle critical errors & signals!
$SIG{__DIE__} = \&trap_die;
$SIG{INT} = \&breakApplication;

# Start logging
$Console->print('---------------------------------------',5);
$Console->print('Selfmonitoring started at '.localtime(),5);
$Console->print("Version $version",5);
$Console->print('---------------------------------------',5);

#
# Open and append configuration variables
#
my $CFG                 = Nimbus::CFG->new("selfmonitoring.cfg");
my $Domain              = $CFG->{"setup"}->{"domain"} || undef;
my $Cache_delay         = $CFG->{"setup"}->{"output_cache_time"} || 432000;
my $Audit               = $CFG->{"setup"}->{"audit"} || 0;
my $Output_directory    = $CFG->{"setup"}->{"output_directory"} || "output";
my $retry_count         = $CFG->{"setup"}->{"callback_retry_count"} || 3;
my $Login               = $CFG->{"setup"}->{"nim_login"} || undef;
my $Password            = $CFG->{"setup"}->{"nim_password"} || undef;
my $GO_Intermediate     = $CFG->{"configuration"}->{"alarms"}->{"intermediate"} || 0;
my $GO_Spooler          = $CFG->{"configuration"}->{"alarms"}->{"spooler"} || 0;
my $Check_NisBridge     = $CFG->{"configuration"}->{"check_nisbridge"} || "no";
my $Overwrite_HA        = $CFG->{"configuration"}->{"priority_on_ha"} || "no";
my $Checkuptime         = $CFG->{"configuration"}->{"check_hubuptime"} || "no";
my $Maxrobots_per_hub   = $CFG->{"configuration"}->{"maxrobots_per_hub"} || 1250;
my $Uptime_value        = $CFG->{"configuration"}->{"uptime_seconds"} || 600;
my $probes_mon          = 0;
my $ump_mon             = 0;
my @UMPServers;
my $ump_alarm_callback;
my $ump_alarm_probelist;
if(defined $CFG->{"ump_monitoring"}) {
    @UMPServers          = split(',',$CFG->{"ump_monitoring"}->{"servers"});
    $ump_alarm_callback  = $CFG->{"ump_monitoring"}->{"alarm_callback"} || "ump_failcallback";
    $ump_alarm_probelist = $CFG->{"ump_monitoring"}->{"alarm_probelist"} || "ump_probelist_fail";
    if(scalar @UMPServers > 0) {
        $ump_mon = 1;
    }
}
my $deployment_mon = "no";
my $deployment_maxtime;
my $deployment_maxjobs;
if(defined $CFG->{"deployment_monitoring"}) {
    $deployment_mon = "yes"; 
    $deployment_maxtime = $CFG->{"deployment_monitoring"}->{"job_time_threshold"} || 600; 
    $deployment_maxjobs = $CFG->{"deployment_monitoring"}->{"max_jobs"} || 2000;
}

# Declare alarms_manager
my $alarm_manager = new perluim::alarmsmanager($CFG,"alarm_messages");
my $filemap = new perluim::filemap('temporary_alarms.cfg');

# Check if domain is correctly configured
if(not defined($Domain)) {
    trap_die('Domain is not declared in the configuration file!');
    exit(1);
}

#
# Print configuration file
#
$Console->print("Print configuration setup section : ",5);
foreach($CFG->getKeys($CFG->{"setup"})) {
    $Console->print("Configuration : $_ => $CFG->{setup}->{$_}",5);
}
$Console->print('---------------------------------------',5);

#
# Retrieve all probes with the callback
#
my %ProbeCallback   = (); 
if(defined($CFG->{"probes_monitoring"}) and scalar keys $CFG->{"probes_monitoring"} > 0) {
    $probes_mon = 1;
    foreach my $key (keys $CFG->{"probes_monitoring"}) {
        my $callback        = $CFG->{"probes_monitoring"}->{"$key"}->{"callback"};
        my $find            = $CFG->{"probes_monitoring"}->{"$key"}->{"check_keys"};
        my $alarms          = $CFG->{"probes_monitoring"}->{"$key"}->{"alarm_on_probe_deactivated"} || 0;
        my $ha_superiority  = $CFG->{"probes_monitoring"}->{"$key"}->{"ha_superiority"} || "yes";
        my $check_alarmName;
        if(defined($find)) {
            $check_alarmName = $CFG->{"probes_monitoring"}->{"$key"}->{"check_alarm_name"};
        }
        $ProbeCallback{"$key"} = { 
            callback => $callback,
            alarms => $alarms,
            ha_superiority => $ha_superiority,
            find => $find,
            check_alarmName => $check_alarmName
        };
    }
}

#
# nimLogin if login and password are defined in the configuration!
#
nimLogin($Login,$Password) if defined($Login) && defined($Password);

#
# Declare framework, create / clean output directory.
# 
$SDK                = new perluim::main("$Domain");
$Final_directory    = "$Output_directory/$Execution_Date";
perluim::utils::createDirectory("$Output_directory/$Execution_Date");
$Console->cleanDirectory("$Output_directory",$Cache_delay);

#
# Main method to call for the script ! 
# main();
# executed at the bottom of this script.
# 
sub main {

    my ($RC_LR,$localRobot) = $SDK->getLocalRobot();
    my ($RC,$hub) = $SDK->getLocalHub();
    if($RC == NIME_OK && $RC_LR == NIME_OK) {
        $Console->print("Start processing $hub->{name} !!!",5);
        $Console->print('---------------------------------------',5);

        my $suppkey_uptime = "selfmonitoring_uptime";
        if($Checkuptime eq "yes") {
            $Console->print("Check hub uptime !");
            if($hub->{uptime} <= $Uptime_value) {
                $Console->print("Uptime is under the threshold of $Uptime_value",2);
                my $hub_restart = $alarm_manager->get('hub_restart');
                my %AlarmObject = (
                    robot => $localRobot,
                    origin => $localRobot->{origin},
                    domain => $Domain,
                    source => "$hub->{ip}",
                    dev_id => $localRobot->{robot_device_id},
                    usertag1 => $localRobot->{os_user1},
                    usertag2 => $localRobot->{os_user2},
                    probe => "selfmonitoring",
                    supp_key => "$suppkey_uptime",
                    suppression => "$suppkey_uptime",
                    second => "$Uptime_value",
                    hubName => "$hub->{name}"
                );
                my ($RC,$AlarmID) = $hub_restart->customCall(\%AlarmObject);

                if($RC == NIME_OK) {
                    $Console->print("Alarm generated : $AlarmID - [$hub_restart->{severity}] - $hub_restart->{subsystem}");
                    my %Args = (
                        suppkey => "$suppkey_uptime"
                    );
                    $filemap->set("$suppkey_uptime",\%Args);
                    $filemap->writeToDisk();
                }
                else {
                    $Console->print("Failed to create alarm!",1);
                }
            }
            else {
                if($filemap->has("$suppkey_uptime")) {
                    my $hub_restart = $alarm_manager->get('hub_restart');
                    my %AlarmObject = (
                        severity => 0,
                        robot => $localRobot,
                        origin => $localRobot->{origin},
                        domain => $Domain,
                        source => "$hub->{ip}",
                        dev_id => $localRobot->{robot_device_id},
                        usertag1 => $localRobot->{os_user1},
                        usertag2 => $localRobot->{os_user2},
                        probe => "selfmonitoring",
                        supp_key => "$suppkey_uptime",
                        suppression => "$suppkey_uptime",
                        second => "0",
                        hubName => "$hub->{name}"
                    );
                    my ($RC,$AlarmID) = $hub_restart->customCall(\%AlarmObject);

                    if($RC == NIME_OK) {
                        $Console->print("Clear generated : $AlarmID - [0] - $hub_restart->{subsystem}");
                        $filemap->delete("$suppkey_uptime");
                        $filemap->writeToDisk();
                    }
                    else {
                        $Console->print("Failed to generate alarm clear!",1);
                    }
                }
            }
            $Console->print('---------------------------------------',5);
        }

        #
        # local_probeList(); , retrive all probes from remote hub.
        #
        { # Memory optimization 
            my $trycount = $retry_count; # Get configuration max_retry for probeList method.
            my $success = 0;

            # Retry to execute probeList multiple times if RC != NIME_OK.
            WH: while($trycount--) {
                my $echotry = 3 - $trycount; # Reverse number
                $Console->print("Execute local_probeList() , try n'$echotry");
                if( checkProbes($hub) ) {
                    $success = 1;
                    last WH; # Kill retry while.
                }
                $| = 1; # Buffer I/O fix
                perluim::utils::doSleep(3); # Pause script for 3 seconds.
            }

            # Final success condition (if all try are failed!).
            $Console->print("Failed to execute local_probeList()",1) if not $success;
        }

        #
        # getLocalRobots() , retrieve all robots from remote hub.
        #
        { # Memory optimization

            my $trycount = $retry_count; # Get configuration max_retry for probeList method.
            my $success = 0;

            WH: while($trycount--) {
                my $echotry = 3 - $trycount; # Reverse number
                $Console->print("Execute getLocalRobots() , try n'$echotry");
                if( checkRobots($hub,$localRobot) ) {
                    $success = 1;
                    last WH; # Kill retry while.
                }
                $| = 1; # Buffer I/O fix
                perluim::utils::doSleep(3); # Pause script for 3 seconds.
            }

            # Final success condition (when all callback are failed).
            $Console->print("Failed to execute getLocalRobots()",1) if not $success;
        }

        # UMP Monitoring
        if($ump_mon) {
            $Console->print("Start monitoring of UMP Servers.."); 
            $Console->print("Servers to check : @UMPServers");
            checkUMP($hub);
        }
         
        return 1;
    }
    else {
        $Console->print('Failed to get local hub or local robot!',0);
        $Console->print("RC: $RC, RC_LC: $RC_LC",0);
        return 0;
    }
}

#
# Method to check all the robots from a specific hub object.
# checkRobots($hub);
# used in main() method.
# 
sub checkRobots {
    my ($hub,$localRobot) = @_;

    my ($RC,@RobotsList) = $hub->local_robotsArray();
    if($RC == NIME_OK) {

        # Create array 
        my @Arr_intermediateRobots = ();
        my @Arr_spooler = (); 
        my %Stats = (
            intermediate => 0,
            spooler => 0
        );

        $Console->print("Starting robots with Intermediate => $GO_Intermediate and Spooler => $GO_Spooler",5);
        $Console->print('---------------------------------------',5);

        # Maximum robots ! 
        my $suppkey_maxrobots = "selfmon_maxrobots_$robot->{name}";
        if(scalar @RobotsList > $Maxrobots_per_hub) {
            my $maxrobots = $alarm_manager->get('maxrobots');
            my %AlarmObject = (
                hubName => "$hub->{name}",
                robot => $localRobot,
                origin => $localRobot->{origin},
                domain => $Domain,
                source => "$hub->{ip}",
                dev_id => $localRobot->{robot_device_id},
                usertag1 => $localRobot->{os_user1},
                usertag2 => $localRobot->{os_user2},
                probe => "selfmonitoring",
                supp_key => "$suppkey_maxrobots",
                suppression => "$suppkey_maxrobots"
            );
            my ($rc_alarm,$alarmid) = $maxrobots->customCall(\%AlarmObject);

            if($rc_alarm == NIME_OK) {
                $Console->print("Alarm generated : $alarmid - [$maxrobots->{severity}] - $maxrobots->{subsystem}");
                my %Args = (
                    suppkey => "$suppkey_maxrobots"
                );
                $filemap->set("$suppkey_maxrobots",\%Args);
                $filemap->writeToDisk();
            }
            else {
                $Console->print("Failed to create alarm!",1);
            }
        }
        else {
            if($filemap->has("$suppkey_maxrobots")) {
                my $maxrobots = $alarm_manager->get('maxrobots');
                my %AlarmObject = (
                    severity => 0,
                    hubName => "$hub->{name}",
                    robot => $localRobot,
                    origin => $localRobot->{origin},
                    domain => $Domain,
                    source => "$hub->{ip}",
                    dev_id => $localRobot->{robot_device_id},
                    usertag1 => $localRobot->{os_user1},
                    usertag2 => $localRobot->{os_user2},
                    probe => "selfmonitoring",
                    supp_key => "$suppkey_maxrobots",
                    suppression => "$suppkey_maxrobots"
                );
                my ($rc_alarm,$alarmid) = $maxrobots->customCall(\%AlarmObject);

                if($rc_alarm == NIME_OK) {
                    $Console->print("Alarm generated : $alarmid - [0] - $maxrobots->{subsystem}");
                    $filemap->delete("$suppkey_maxrobots");
                    $filemap->writeToDisk();
                }
                else {
                    $Console->print("Failed to create alarm!",1);
                }
            }
        }
        undef $suppkey_maxrobots;

        # Foreach robots
        foreach my $robot (@RobotsList) {
            next if "$robot->{status}" eq "2";

            if("$robot->{status}" eq "1") {
                push(@Arr_intermediateRobots,"$robot->{name}");
                $Stats{intermediate}++;
            }

            if($GO_Spooler) {
                # Callback spooler!
                my $S_RC = spoolerCallback($robot->{name});
                my $suppkey_spooler = "selfmon_spoolercb_$robot->{name}_spooler";
                if($S_RC != NIME_OK) {
                    push(@Arr_spooler,"$robot->{name}");
                    $Stats{spooler}++;

                    if(not $Audit) {
                        # Generate alarm!
                        my $spooler_fail = $alarm_manager->get('spooler_fail');
                        my %AlarmObject = (
                            hubname => "$hub->{name}",
                            robot => $robot,
                            domain => $Domain,
                            origin => $robot->{origin},
                            source => "$hub->{ip}",
                            dev_id => $robot->{robot_device_id},
                            usertag1 => $robot->{os_user1},
                            usertag2 => $robot->{os_user2},
                            probe => "selfmonitoring",
                            supp_key => "$suppkey_spooler",
                            suppression => "$suppkey_spooler"
                        );
                        my ($rc_alarm,$alarmid) = $spooler_fail->customCall(\%AlarmObject);

                        if($rc_alarm == NIME_OK) {
                            $Console->print("Alarm generated : $alarmid - [$spooler_fail->{severity}] - $spooler_fail->{subsystem}");
                            my %Args = (
                                suppkey => "$suppkey_spooler"
                            );
                            $filemap->set("$suppkey_spooler",\%Args);
                            $filemap->writeToDisk();
                        }
                        else {
                            $Console->print("Failed to create alarm!",1);
                        }
                    }
                }
                elsif( $filemap->has("$suppkey_spooler") ) {

                    my $spooler_fail = $alarm_manager->get('spooler_fail');
                    my %AlarmObject = (
                        severity => 0,
                        hubname => "$hub->{name}",
                        robot => $robot,
                        domain => $Domain,
                        origin => $robot->{origin},
                        source => "$hub->{ip}",
                        dev_id => $robot->{robot_device_id},
                        usertag1 => $robot->{os_user1},
                        usertag2 => $robot->{os_user2},
                        probe => "selfmonitoring",
                        supp_key => "$suppkey_spooler",
                        suppression => "$suppkey_spooler"
                    );
                    my ($rc_alarm,$alarmid) = $spooler_fail->customCall(\%AlarmObject);

                    if($rc_alarm == NIME_OK) {
                        $Console->print("Clear generated : $alarmid - [0] - $spooler_fail->{subsystem}");
                        $filemap->delete("$suppkey_spooler");
                        $filemap->writeToDisk();
                    }
                    else {
                        $Console->print("Failed to generate Clear!",1);
                    }

                }
            }

        }

        $Console->print('---------------------------------------',5);
        $Console->print('Final statistiques :',5);
        foreach(keys %Stats) {
            $Console->print("$_ => $Stats{$_}");
        }

        my $int_identifier = "selfmon_intermediateRobot";
        if($Stats{intermediate} > 0 && $GO_Intermediate && not $Audit) {
            my $intermediate_robot = $alarm_manager->get('intermediate_robot');
            my %AlarmObject = (
                count => $Stats{intermediate},
                hubName => "$hub->{name}",
                robot => $localRobot,
                origin => $localRobot->{origin},
                domain => $Domain,
                source => "$hub->{ip}",
                dev_id => $localRobot->{robot_device_id},
                usertag1 => $localRobot->{os_user1},
                usertag2 => $localRobot->{os_user2},
                probe => "selfmonitoring",
                supp_key => "$int_identifier",
                suppression => "$int_identifier"
            );
            my ($rc_alarm,$alarmid) = $intermediate_robot->customCall(\%AlarmObject);

            if($rc_alarm == NIME_OK) {
                $Console->print("Alarm generated : $alarmid - [$intermediate_robot->{severity}] - $intermediate_robot->{subsystem}");
                my %Args = (
                    suppkey => "$int_identifier"
                );
                $filemap->set("$int_identifier",\%Args);
                $filemap->writeToDisk();
            }
            else {
                $Console->print("Failed to create alarm!",1);
            }
        }
        else {
            if($filemap->has("$int_identifier")) {
                my $intermediate_robot = $alarm_manager->get('intermediate_robot');
                my %AlarmObject = (
                    severity => 0,
                    count => $Stats{intermediate},
                    hubName => "$hub->{name}",
                    robot => $localRobot,
                    origin => $localRobot->{origin},
                    source => "$hub->{ip}",
                    dev_id => $localRobot->{robot_device_id},
                    usertag1 => $localRobot->{os_user1},
                    usertag2 => $localRobot->{os_user2},
                    domain => $Domain,
                    probe => "selfmonitoring",
                    supp_key => "$int_identifier",
                    suppression => "$int_identifier"
                );
                my ($rc_alarm,$alarmid) = $intermediate_robot->customCall(\%AlarmObject);

                if($rc_alarm == NIME_OK) {
                    $Console->print("Clear generated : $alarmid - [0] - $intermediate_robot->{subsystem}");
                    $filemap->delete("$int_identifier");
                    $filemap->writeToDisk();
                }
                else {
                    $Console->print("Failed to generate Clear!",1);
                }
            }
        }

        # Write file to the disk.
        $Console->print("Write output files to the disk..");
        new perluim::filereader()->save("output/$Execution_Date/intermediate_servers.txt",\@Arr_intermediateRobots);
        new perluim::filereader()->save("output/$Execution_Date/failedspooler_servers.txt",\@Arr_spooler);

        $Console->print('---------------------------------------',5);

        return 1;
    }
    else {
        $Console->print('Failed to get robotslist from hub',0);
        return 0;
    }
}

#
# send get_info callback to spooler probe.
# spoolerCallback($robotname);
# used in checkRobots() method.
# 
sub spoolerCallback {
    my $robot_name = shift;
    my $PDS = pdsCreate();
    $Console->print("nimRequest : $robot_name - 48001 - get_info",4);
    my ($RC,$RES) = nimRequest("$robot_name",48001,"get_info",$PDS);
    pdsDelete($PDS);
    return $RC;
}

#
# Method to check all the probes from a specific hub object.
# checkProbes($hub);
# used in main() method.
# 
sub checkProbes {
    my ($hub) = @_;
    my ($RC,@ProbesList) = $hub->local_probeList();
    my ($RC_Getinfo,$RobotInfo) = $hub->local_getInfo(); 

    if($RC == NIME_OK && $RC_Getinfo == NIME_OK) {
        $Console->print("hub->ProbeList() has been executed successfully!");
        my $find_nas = 0;
        my $find_ha = 0;
        my $find_distsrv = 0;
        my $distsrv_port; 
        my $ha_port;

        #
        # First while to find NAS and HA Probe
        #
        foreach my $probe (@ProbesList) {
            if($probe->{name} eq "nas") {
                $find_nas = 1;
            }
            elsif($probe->{name} eq "HA") {
                $find_ha = 1;
                $ha_port = $probe->{port}; # Get HA port because it's dynamic
            }
            elsif($probe->{name} eq "distsrv") {
                $find_distsrv = 1; 
                $distsrv_port = $probe->{port};
            }   
        }

        #
        # If HA is here, find the status
        #
        my $ha_value;
        if($find_ha) {
            my $PDS = pdsCreate();
            $Console->print("nimRequest : $hub->{robotname} - HA - get_status",4);
            my ($RC,$RES) = nimRequest("$hub->{robotname}",$ha_port,"get_status",$PDS);
            pdsDelete($PDS);

            if($RC == NIME_OK) {
                $ha_value = (Nimbus::PDS->new($RES))->get("connected");
                $Console->print("Successfully retrived HA connected value => $ha_value");
            }
            else {
                $Console->print("Failed to get HA status!",1);
                $find_ha = 0;
            }
        }
        undef $ha_port;


        if($probes_mon) {
            # While all probes retrieving 
            foreach my $probe (@ProbesList) {

                # Verify if we have to check this probe or not!
                if(exists( $ProbeCallback{$probe->{name}} )) {

                    $Console->print('---------------------------------------',5);
                    $Console->print("Prepare checkup for $probe->{name}, Active => $probe->{active}");
                    my $callback        = $ProbeCallback{$probe->{name}}{callback};
                    my $callAlarms      = $ProbeCallback{$probe->{name}}{alarms};
                    my $ha_superiority  = $ProbeCallback{$probe->{name}}{ha_superiority};
                    my $find            = $ProbeCallback{$probe->{name}}{find};
                    my $check_alarmName = $ProbeCallback{$probe->{name}}{check_alarmName};
                    my $suppkey_poffline = "selfmon_probeoffline_$hub->{robotname}_$probe->{name}";

                    # Verify if the probe is active or not!
                    
                    if($probe->{active} == 1) {

                        if($filemap->has($suppkey_poffline)) {
                            my $probe_offline = $alarm_manager->get('probe_offline');
                            my ($RC_ALARM,$AlarmID) = $probe_offline->customCall({ 
                                severity => 0,
                                domain => $Domain,
                                probeName => "$probe->{name}",
                                probe => "selfmonitoring",
                                origin => $RobotInfo->{origin},
                                robotname => $hub->{robotname},
                                source => "$hub->{ip}",
                                dev_id => $RobotInfo->{robot_device_id},
                                usertag1 => $RobotInfo->{os_user1},
                                usertag2 => $RobotInfo->{os_user2},
                                supp_key => "$suppkey_poffline",
                                suppression => "$suppkey_poffline"
                            });

                            if($RC_ALARM == NIME_OK) {
                                $Console->print("Generate clear : $AlarmID - [0] - $probe_offline->{subsystem}");
                                $filemap->delete($suppkey_poffline);
                                $filemap->writeToDisk();
                            }
                            else {
                                $Console->print("Failed to generate clear! (RC: $RC_ALARM)",1);
                            }

                        }
                        if(defined($callback)) {
                            doCallback($hub->{robotname},$hub->{name},$probe->{name},$probe->{port},$callback,$find,$check_alarmName,$RobotInfo) if not $Audit;
                        }
                        else {
                            $Console->print("Callback is not defined!");
                        }
                    }
                    else {

                        # Verify we have the right to launch a alarm.
                        # Note, if Overwrite_HA is set to yes and we are on a HA situation, the alarms key is overwrited.
                        if(not $Audit and $callAlarms or ($find_ha and $Overwrite_HA eq "yes" and "$ha_value" eq "0" and $ha_superiority eq "yes" ) ) {
                            $Console->print("Probe is inactive, generate new alarm!",2);
                            my $probe_offline = $alarm_manager->get('probe_offline');

                            my ($RC_ALARM,$AlarmID) = $probe_offline->customCall({ 
                                probeName => "$probe->{name}",
                                probe => "selfmonitoring",
                                robotname => $hub->{robotname},
                                domain => $Domain,
                                hubname => "$hub->{name}",
                                source => "$hub->{ip}",
                                origin => $RobotInfo->{origin},
                                dev_id => $RobotInfo->{robot_device_id},
                                usertag1 => $RobotInfo->{os_user1},
                                usertag2 => $RobotInfo->{os_user2},
                                supp_key => "$suppkey_poffline",
                                suppression => "$suppkey_poffline"
                            });

                            if($RC_ALARM == NIME_OK) {
                                $Console->print("Alarm generated : $AlarmID - [$probe_offline->{severity}] - $probe_offline->{subsystem}");
                                $filemap->set($suppkey_poffline,{
                                    suppkey => $suppkey_poffline
                                });
                                $filemap->writeToDisk();
                            }
                            else {
                                $Console->print("Failed to create alarm! (RC: $RC_ALARM)",1);
                            }
                            
                        }
                        else {
                            $Console->print("Probe is inactive !");
                        }

                    }

                }
            }
        }

        if($find_nas && $Check_NisBridge eq "yes") {
            $Console->print('---------------------------------------',5);
            $Console->print('Checkup NisBridge configuration');
            checkNisBridge($hub->{robotname},$hub->{name},$find_ha,$ha_value,$RobotInfo);
        }

        if($find_distsrv && $deployment_mon eq "yes") {
            $Console->print('---------------------------------------',5);
            $Console->print('Checkup Distsrv jobs!');
            checkDistsrv($hub,$distsrv_port,$RobotInfo);
            $Console->print('---------------------------------------',5);
        }

        return 1;
    }
    return 0;
}

#
# Method to do a callback on a specific probe.
# doCallback($robotname,$probeName,$probePort,$callback,$find)
# used in checkProbes() method.
# 
sub doCallback {
    my ($robotname,$hubname,$probeName,$probePort,$callback,$check_keys,$check_alarmName,$RobotInfo) = @_;
    my $PDS = pdsCreate();

    # Special rule for NAS only!
    if(uc $probeName eq "NAS") {
        pdsPut_INT($PDS,"detail",1);
    }

    $Console->print("nimRequest : $robotname - $probePort - $callback",4);
    my ($CALLBACK_RC,$RES) = nimRequest("$robotname",$probePort,"$callback",$PDS);
    pdsDelete($PDS);

    $Console->print("Return code : $CALLBACK_RC",4);
    my $suppkey_fail = "selfmon_cbfail_${robotname}_${probeName}";
    if($CALLBACK_RC != NIME_OK) {

        $Console->print("Return code is not OK ! Generating a alarm.",2);
        my $callback_fail = $alarm_manager->get('callback_fail');
        my ($RC,$AlarmID) = $callback_fail->customCall({ 
            callback => "$callback", 
            domain => $Domain,
            robotname => "$robotname",
            source => "$robotname",
            probeName => "$probeName", 
            probe => "selfmonitoring",
            hubname => "$hubname",
            origin => $RobotInfo->{origin},
            dev_id => $RobotInfo->{robot_device_id},
            usertag1 => $RobotInfo->{os_user1},
            usertag2 => $RobotInfo->{os_user2},
            port => "$probePort",
            supp_key => "$suppkey_fail",
            suppression => "$suppkey_fail"
        });

        if($RC == NIME_OK) {
            $Console->print("Alarm generated : $AlarmID - [$callback_fail->{severity}] - $callback_fail->{subsystem}");
            $filemap->set($suppkey_fail);
            $filemap->writeToDisk();
        }
        else {
            $Console->print("Failed to create alarm! (RC: $RC)",1);
        }
    }
    else {

        if($filemap->has($suppkey_fail)) {
            my $callback_fail = $alarm_manager->get('callback_fail');
            my ($RC,$AlarmID) = $callback_fail->customCall({ 
                severity => 0,
                domain => $Domain,
                callback => "$callback", 
                source => "$robotname",
                robotname => "$robotname",
                origin => $RobotInfo->{origin},
                dev_id => $RobotInfo->{robot_device_id},
                usertag1 => $RobotInfo->{os_user1},
                usertag2 => $RobotInfo->{os_user2},
                probeName => "$probeName", 
                probe => "selfmonitoring",
                hubname => "$hubname",
                port => "$probePort",
                supp_key => "$suppkey_fail",
                suppression => "$suppkey_fail"
            });

            if($RC == NIME_OK) {
                $Console->print("Alarm clear : $AlarmID - [$callback_fail->{severity}] - $callback_fail->{subsystem}");
                $filemap->delete($suppkey_fail);
                $filemap->writeToDisk();
            }
            else {
                $Console->print("Failed to generate alarm clear! (RC: $RC)",1);
            }
        }

        if(defined($check_keys)) {
            $Console->print("doCallback: Entering into check_keys");
            my $key_ok = 0;
            my $object_value;
            my $expected_value;
            foreach (keys $check_keys) {
                my $type = ref($check_keys->{$_});

                if($type eq "HASH") {
                    my $PDS = Nimbus::PDS->new($RES);
                    my $count = 0;
                    WONE: for(; my $OInfo = $PDS->getTable("$_",PDS_PDS,$count); $count++) {

                        foreach my $id (keys $check_keys->{$_}) {

                            my $match_all_key = 1;
                            WTWO: foreach my $sec_key (keys $check_keys->{$_}->{$id}) {
                                $object_value    = $OInfo->get("$sec_key");
                                $expected_value  = $check_keys->{$_}->{$id}->{$sec_key};
                                next if not defined($object_value);

                                my $strBegin = perluim::utils::strBeginWith($expected_value,"<<");
                                my $condition = $strBegin ? $object_value <= substr($expected_value,2) : $object_value eq $expected_value;

                                if(not $condition) {
                                    $match_all_key = 0;
                                    last WTWO;
                                }

                            }

                            if($match_all_key) {
                                $key_ok = 1;
                                last WONE;
                            }

                        }
                        
                    }
                }
                else {
                    my $value = (Nimbus::PDS->new($RES))->get("$_");
                    if(defined($value) and $value == $check_keys->{$_}) {
                        $key_ok = 1;
                    }
                }

            }
            $Console->print("doCallback: exit check_keys with RC => $key_ok",2);

            if(not $key_ok and not $Audit && defined($check_alarmName)) {
                # Generate alarm!
                $Console->print("doCallback: Generate a new check_configuration alarm!");
                my $customAlarm = $alarm_manager->get("$check_alarmName");
                my ($RC,$AlarmID) = $customAlarm->call({ 
                    robotname => "$robotname",
                    hubname => "$hubname"
                });

                if($RC == NIME_OK) {
                    $Console->print("Alarm generated : $AlarmID - [$customAlarm->{severity}] - $customAlarm->{subsystem}");
                }
                else {
                    $Console->print("Failed to create alarm!",1);
                }
            }
        }
    }
}

#
# retrieve nis_bridge key in NAS and return it.
# checkNisBridge($robotname,$hubname,$ha,$ha_value)
# used in checkProbes() method
#
sub checkNisBridge {
    my ($robotname,$hubname,$ha,$ha_value,$RobotInfo) = @_; 
    my $nis_value;

    # Generate alarm variable!
    my $generate_alarm = 1;
    {
        $Console->print("nimRequest : $robotname - 48000 - probe_config_get",4);
        my $pds = new Nimbus::PDS();
        $pds->put('name','nas',PDS_PCH);
        $pds->put('var','/setup/nis_bridge',PDS_PCH);
        my ($RC,$RES) = nimRequest("$robotname",48000,"probe_config_get",$pds->data());

        if($RC == NIME_OK) {
            $nis_value = (Nimbus::PDS->new($RES))->get("value");
            if($ha) {
                if ( (not $ha_value and $nis_value eq "yes") || ($ha_value and $nis_value eq "no") ) {
                    $generate_alarm = 0;
                }
            }
            else {
                if($nis_value eq "yes") {
                    $generate_alarm = 0;
                }
            }
        }
        else {
            # TODO : Generate another alarm ?
            $Console->print("Failed to get nis_bridge configuration with RC $RC!",1);
            return;
        }
    }

    # Generate alarm
    my $suppkey_nisbridge = "selfmon_nisfail_${robotname}_nas";
    if($generate_alarm) {
        $Console->print("Generating new alarm for NIS_Bridge",2);
        $Console->print("Nis_bridge => $nis_value",4);
        $Console->print("HA connected => $ha_value",4);
        my $nis_alarm = $alarm_manager->get('nisbridge');
        my ($RC,$AlarmID) = $nis_alarm->customCall({ 
            robotname => "$robotname", 
            hubname => "$hubname",
            domain => $Domain,
            nis => "$nis_value",
            ha => "$ha_value",
            origin => $RobotInfo->{origin},
            dev_id => $RobotInfo->{robot_device_id},
            usertag1 => $RobotInfo->{os_user1},
            usertag2 => $RobotInfo->{os_user2},
            supp_key => "$suppkey_nisbridge",
            suppression => "$suppkey_nisbridge"
        });

        if($RC == NIME_OK) {
            $Console->print("Alarm generated : $AlarmID - [$nis_alarm->{severity}] - $nis_alarm->{subsystem}");
            $filemap->set($suppkey_nisbridge);
        }
        else {
            $Console->print("Failed to create alarm!",1);
        }
    }
    else {

        if($filemap->has($suppkey_nisbridge)) {
            my $nis_alarm = $alarm_manager->get('nisbridge');
            my ($RC,$AlarmID) = $nis_alarm->customCall({ 
                severity => 0,
                robotname => "$robotname", 
                hubname => "$hubname",
                domain => $Domain,
                nis => "$nis_value",
                ha => "$ha_value",
                origin => $RobotInfo->{origin},
                dev_id => $RobotInfo->{robot_device_id},
                usertag1 => $RobotInfo->{os_user1},
                usertag2 => $RobotInfo->{os_user2},
                supp_key => "$suppkey_nisbridge",
                suppression => "$suppkey_nisbridge"
            });

            if($RC == NIME_OK) {
                $Console->print("Alarm clear : $AlarmID - [0] - $nis_alarm->{subsystem}");
                $filemap->delete($suppkey_nisbridge);
            }
            else {
                $Console->print("Failed to generate clear alarm!",1);
            }
        }
        $Console->print("Nis_bridge ... OK!");
    }
}

# 
# Check all distsrv jobs !
# checkDistsrv($hub)
# used in main() method
#
sub checkDistsrv {
    my ($hub,$distsrv_port,$RobotInfo) = @_; 

    my $pds = pdsCreate(); 
    my ($RC,$RES) = nimRequest($hub->{robotname},$distsrv_port,"job_list",$pds);
    pdsDelete($pds); 

    my $suppkey_distsrv = "selfmon_cbfail_$hub->{robotname}_distsrv";

    if($RC == NIME_OK) {

        if($filemap->has($suppkey_distsrv)) {
            my $callback_fail = $alarm_manager->get("callback_fail");
            my ($RC_ALARM,$AlarmID) = $callback_fail->customCall({ 
                severity => 0,
                callback => "job_list",
                robotname => "$hub->{robotname}",
                domain => $Domain,
                probe => "distsrv",
                hubname => "$hub->{name}",
                source => "$hub->{ip}",
                origin => $RobotInfo->{origin},
                dev_id => $RobotInfo->{robot_device_id},
                usertag1 => $RobotInfo->{os_user1},
                usertag2 => $RobotInfo->{os_user2},
                supp_key => "$suppkey_distsrv",
                suppression => "$suppkey_distsrv"
            });

            if($RC_ALARM == NIME_OK) {
                $Console->print("Alarm clear : $AlarmID - [0] - $callback_fail->{subsystem}");
                $filemap->delete($suppkey_distsrv);
            }
            else {
                $Console->print("Failed to generate alarm clear!",1);
            }
        }

        my $JOB_PDS = Nimbus::PDS->new($RES);
        my $count;
        for( $count = 0; my $JobNFO = $JOB_PDS->getTable("entry",PDS_PDS,$count); $count++) {
            my $Job = new perluim::dtsrvjob($JobNFO);
            $Console->print("Processing Job number $count");
            next if $Job->{status} eq "finished";

            my $date1;
            {
                my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($Job->{time_started});
                $year+= 1900;
                $date1 = sprintf("%02d:%02d:%02d %02d:%02d:%02d",$year,($mon+1),$mday,$hour,$min,$sec);
            }

            my $date2;
            {
                my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
                $year+= 1900;
                $date2 = sprintf("%02d:%02d:%02d %02d:%02d:%02d",$year,($mon+1),$mday,$hour,$min,$sec);
            }
            my $format = '%Y:%m:%d %H:%M:%S';
            my $diff = Time::Piece->strptime($date2, $format) - Time::Piece->strptime($date1, $format);
            if($diff > $deployment_maxtime and not $Audit) {
                my $distsrv_deployment = $alarm_manager->get("distsrv_deployment");
                my ($RC_ALARM,$AlarmID) = $distsrv_deployment->call({ 
                    jobid => "$Job->{job_id}",
                    pkgName => "$Job->{package_name}",
                    started => "$Job->{time_started}",
                    diff => "$diff",
                    probe => "distsrv",
                    hubname => "$hub->{name}",
                    robotName => "$hub->{robotname}"
                });

                if($RC_ALARM == NIME_OK) {
                    $Console->print("Alarm generated : $AlarmID - [$distsrv_deployment->{severity}] - $distsrv_deployment->{subsystem}");
                }
                else {
                    $Console->print("Failed to create alarm!",1);
                }
            }
        }

        if($count >= $deployment_maxjobs and not $Audit) {
            $Console->print("Max jobs count reached!");
            my $distsrv_maxjobs = $alarm_manager->get("distsrv_maxjobs");
            my ($RC_ALARM,$AlarmID) = $distsrv_maxjobs->call({ 
                max => "$deployment_maxjobs",
                count => "$count",
                probe => "distsrv",
                hubname => "$hub->{name}",
                robotName => "$hub->{robotname}"
            });

            if($RC_ALARM == NIME_OK) {
                $Console->print("Alarm generated : $AlarmID - [$distsrv_maxjobs->{severity}] - $distsrv_maxjobs->{subsystem}");
            }
            else {
                $Console->print("Failed to create alarm!",1);
            }
        }

    }
    else {
        if(not $Audit) {
            my $callback_fail = $alarm_manager->get("callback_fail");
            my ($RC_ALARM,$AlarmID) = $callback_fail->customCall({ 
                callback => "job_list",
                probe => "distsrv",
                domain => $Domain,
                robotname => "$hub->{robotname}",
                hubname => "$hub->{name}",
                source => "$hub->{ip}",
                origin => $RobotInfo->{origin},
                dev_id => $RobotInfo->{robot_device_id},
                usertag1 => $RobotInfo->{os_user1},
                usertag2 => $RobotInfo->{os_user2},
                supp_key => "$suppkey_distsrv",
                suppression => "$suppkey_distsrv"
            });

            if($RC_ALARM == NIME_OK) {
                $Console->print("Alarm generated : $AlarmID - [$callback_fail->{severity}] - $callback_fail->{subsystem}");
                $filemap->set($suppkey_distsrv);
            }
            else {
                $Console->print("Failed to create alarm!",1);
            }
        }
    }
}

# 
# Check all Wasp probes from UMP Servers.
# checkUMP($hub)
# used in main() method
#
sub checkUMP {
    my ($hub) = @_;
    my ($RC_Getinfo,$RobotInfo) = $hub->local_getInfo(); 

    if($RC_Getinfo != NIME_OK) {
        return;
    }

    foreach(@UMPServers) {
        $Console->print("Processing check on ump $_"); 

        my $suppkey_ump_probes = "selfmon_probeslistfail_$hub->{robotname}_ump";
        my $suppkey_ump_cbfail = "selfmon_cbfail_$hub->{robotname}_ump";

        my $ERR = 0;
        my $pds = new Nimbus::PDS();
        $pds->put('name','wasp',PDS_PCH);
        my ($RC,$RES) = nimRequest("$_",48000,"probe_list",$pds->data());
        if($RC == NIME_OK) {

            if($filemap->has($suppkey_ump_probes)) {
                my $ump_probelist_fail = $alarm_manager->get("$ump_alarm_probelist");
                my ($RC_ALARM,$AlarmID) = $ump_probelist_fail->call({ 
                    severity => 0,
                    robotname => "$hub->{robotname}",
                    umpName => "$_",
                    domain => $Domain,
                    source => "$hub->{ip}",
                    origin => $RobotInfo->{origin},
                    dev_id => $RobotInfo->{robot_device_id},
                    usertag1 => $RobotInfo->{os_user1},
                    usertag2 => $RobotInfo->{os_user2},
                    supp_key => "$suppkey_ump_probes",
                    suppression => "$suppkey_ump_probes"
                });

                if($RC_ALARM == NIME_OK) {
                    $Console->print("Alarm clear : $AlarmID - [$ump_probelist_fail->{severity}] - $ump_probelist_fail->{subsystem}");
                    $filemap->delete($suppkey_ump_probes);
                }
                else {
                    $Console->print("Failed to generate alarm clear!",1);
                }
            }

            $Console->print("Callback probe_list executed succesfully!");
            my $hash = Nimbus::PDS->new($RES)->asHash();

            my $pds_ump = new Nimbus::PDS();
            ($RC,$RES) = nimRequest("$_",$hash->{"wasp"}->{"port"},"get_info",$pds_ump->data());
            if($RC != NIME_OK && not $Audit) {
                $Console->print("Failed to execute callback get_info on wasp probe on $_",1);
                my $ump_failcallback = $alarm_manager->get("$ump_alarm_callback");
                my ($RC_ALARM,$AlarmID) = $ump_failcallback->call({ 
                    umpName => "$_",
                    robotname => "$hub->{robotname}",
                    source => "$hub->{ip}",
                    domain => $Domain,
                    origin => $RobotInfo->{origin},
                    dev_id => $RobotInfo->{robot_device_id},
                    usertag1 => $RobotInfo->{os_user1},
                    usertag2 => $RobotInfo->{os_user2},
                    supp_key => "$suppkey_ump_cbfail",
                    suppression => "$suppkey_ump_cbfail"
                });

                if($RC_ALARM == NIME_OK) {
                    $Console->print("Alarm generated : $AlarmID - [$ump_failcallback->{severity}] - $ump_failcallback->{subsystem}");
                    $filemap->set($suppkey_ump_cbfail);
                }
                else {
                    $Console->print("Failed to create alarm!",1);
                }
            }
            else {
                $Console->print("Callback get_info return ok...");
                
                if($filemap->has($suppkey_ump_cbfail)) {
                    my $ump_failcallback = $alarm_manager->get("$ump_alarm_callback");
                    my ($RC_ALARM,$AlarmID) = $ump_failcallback->call({ 
                        severity => 0,
                        robotname => "$hub->{robotname}",
                        umpName => "$_",
                        source => "$hub->{ip}",
                        origin => $RobotInfo->{origin},
                        dev_id => $RobotInfo->{robot_device_id},
                        usertag1 => $RobotInfo->{os_user1},
                        usertag2 => $RobotInfo->{os_user2},
                        supp_key => "$suppkey_ump_cbfail",
                        suppression => "$suppkey_ump_cbfail"
                    });

                    if($RC_ALARM == NIME_OK) {
                        $Console->print("Alarm clear : $AlarmID - [$ump_failcallback->{severity}] - $ump_failcallback->{subsystem}");
                        $filemap->delete($suppkey_ump_cbfail);
                    }
                    else {
                        $Console->print("Failed to generate alarm clear!",1);
                    }
                }
            }
        }
        else {
            $Console->print("Failed to execute callback probe_list on ump $_",1);
            if(not $Audit) {
                my $ump_probelist_fail = $alarm_manager->get("$ump_alarm_probelist");
                my ($RC_ALARM,$AlarmID) = $ump_probelist_fail->call({ 
                    umpName => "$_",
                    robotname => "$hub->{robotname}",
                    source => "$hub->{ip}",
                    origin => $RobotInfo->{origin},
                    dev_id => $RobotInfo->{robot_device_id},
                    usertag1 => $RobotInfo->{os_user1},
                    usertag2 => $RobotInfo->{os_user2},
                    supp_key => "$suppkey_ump_probes",
                    suppression => "$suppkey_ump_probes"
                });

                if($RC_ALARM == NIME_OK) {
                    $Console->print("Alarm generated : $AlarmID - [$ump_probelist_fail->{severity}] - $ump_probelist_fail->{subsystem}");
                    $filemap->set($suppkey_ump_probes);
                }
                else {
                    $Console->print("Failed to create alarm!",1);
                }
            }
        }

    }
}

#
# Die method
# trap_die($error_message)
# 
sub trap_die {
    my ($err) = @_;
    $filemap->writeToDisk();
    $Console->finalTime($time);
	$Console->print("Program is exiting abnormally : $err",0);
    $| = 1; # Buffer I/O fix
    sleep(2);
    $Console->copyTo("output/$Execution_Date");
}

#
# When application is breaked with CTRL+C
#
sub breakApplication { 
    $filemap->writeToDisk();
    $Console->finalTime($time);
    $Console->print("\n\n Application breaked with CTRL+C \n\n",0);
    $| = 1; # Buffer I/O fix
    sleep(2);
    $Console->copyTo("output/$Execution_Date");
    exit(1);
}

# Call the main method 
main();
$filemap->writeToDisk();

$Console->finalTime($time);
$| = 1; # Buffer I/O fix
sleep(2);
$Console->copyTo($Final_directory);
$Console->close();
