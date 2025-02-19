######################################################################
#
#  88_HMCCUCHN.pm
#
#  $Id: 88_HMCCUCHN.pm 18552 2019-02-10 11:52:28Z zap $
#
#  Version 4.4.031
#
#  (c) 2020 zap (zap01 <at> t-online <dot> de)
#
######################################################################
#  Client device for Homematic channels.
#  Requires module 88_HMCCU.pm
######################################################################

package main;

use strict;
use warnings;
use SetExtensions;

require "$attr{global}{modpath}/FHEM/88_HMCCU.pm";

sub HMCCUCHN_Initialize ($);
sub HMCCUCHN_Define ($@);
sub HMCCUCHN_InitDevice ($$);
sub HMCCUCHN_Undef ($$);
sub HMCCUCHN_Rename ($$);
sub HMCCUCHN_Set ($@);
sub HMCCUCHN_Get ($@);
sub HMCCUCHN_Attr ($@);

######################################################################
# Initialize module
######################################################################

sub HMCCUCHN_Initialize ($)
{
	my ($hash) = @_;

	$hash->{DefFn}    = 'HMCCUCHN_Define';
	$hash->{UndefFn}  = 'HMCCUCHN_Undef';
	$hash->{RenameFn} = 'HMCCUCHN_Rename';
	$hash->{SetFn}    = 'HMCCUCHN_Set';
	$hash->{GetFn}    = 'HMCCUCHN_Get';
	$hash->{AttrFn}   = 'HMCCUCHN_Attr';
	$hash->{parseParams} = 1;

	$hash->{AttrList} = 'IODev ccucalculate '.
		'ccuflags:multiple-strict,ackState,logCommand,noReadings,trace,showMasterReadings,showLinkReadings,showDeviceReadings,showServiceReadings '.
		'ccureadingfilter:textField-long '.
		'ccureadingformat:name,namelc,address,addresslc '.
		'ccureadingname:textField-long ccuSetOnChange ccuReadingPrefix '.
		'ccuscaleval ccuverify:0,1,2 ccuget:State,Value '.
		'disable:0,1 hmstatevals:textField-long statevals substitute:textField-long '.
		'substexcl stripnumber peer:textField-long traceFilter '. $readingFnAttributes;
}

######################################################################
# Define device
######################################################################

sub HMCCUCHN_Define ($@)
{
	my ($hash, $a, $h) = @_;
	my $name = $hash->{NAME};

	my $usage = "Usage: define $name HMCCUCHN {device} ['readonly'] ['noDefaults'|'defaults'] [iodev={iodevname}]";
	return $usage if (@$a < 3);

	my ($devname, $devtype, $devspec) = splice (@$a, 0, 3);
	my $ioHash;

	my $existDev = HMCCU_ExistsClientDevice ($devspec, $devtype);
	return "FHEM device $existDev for CCU device $devspec already exists" if ($existDev ne '');
		
	# Store some definitions for delayed initialization
	$hash->{hmccu}{devspec} = $devspec;
	
	# Defaults
	$hash->{readonly} = 'no';
	$hash->{hmccu}{channels} = 1;
	$hash->{hmccu}{nodefaults} = $init_done ? 0 : 1;
	$hash->{hmccu}{semDefaults} = 0;
	
	# Parse optional command line parameters
	my $n = 0;
	while (my $arg = shift @$a) {
		return $usage if ($n == 3);
		if    ($arg eq 'readonly')                     { $hash->{readonly} = 'yes'; }
		elsif (lc($arg) eq 'nodefaults' && $init_done) { $hash->{hmccu}{nodefaults} = 1; }
		elsif ($arg eq 'defaults' && $init_done)       { $hash->{hmccu}{nodefaults} = 0; }
		else                                           { return $usage; }
		$n++;
	}
	
	# IO device can be set by command line parameter iodev, otherwise try to detect IO device
	if (exists($h->{iodev})) {
		return "Device $h->{iodev} does not exist" if (!exists($defs{$h->{iodev}}));
		return "Type of device $h->{iodev} is not HMCCU" if ($defs{$h->{iodev}}->{TYPE} ne 'HMCCU');
		$ioHash = $defs{$h->{iodev}};
	}
	else {
		# The following call will fail during FHEM start if CCU is not ready
		$ioHash = HMCCU_FindIODevice ($devspec);
	}
	
	if ($init_done) {
		# Interactive define command while CCU not ready or no IO device defined
		if (!defined($ioHash)) {
			my ($ccuactive, $ccuinactive) = HMCCU_IODeviceStates ();
			return $ccuinactive > 0 ?
				'CCU and/or IO device not ready. Please try again later' :
				'Cannot detect IO device or CCU device not found';
		}
	}
	else {
		# CCU not ready during FHEM start
		if (!defined($ioHash) || $ioHash->{ccustate} ne 'active') {
			HMCCU_Log ($hash, 2, 'Cannot detect IO device, maybe CCU not ready. Trying later ...');
			$hash->{ccudevstate} = 'pending';
			return undef;
		}
	}
	
	# Initialize FHEM device, set IO device
	my $rc = HMCCUCHN_InitDevice ($ioHash, $hash);
	return 'Invalid or unknown CCU channel name or address' if ($rc == 1);
	return "Can't assign I/O device $ioHash->{NAME}" if ($rc == 2);

	return undef;
}

######################################################################
# Initialization of FHEM device.
# Called during Define() or by HMCCU after CCU ready.
# Return 0 on successful initialization or >0 on error:
# 1 = Invalid channel name or address
# 2 = Cannot assign IO device
######################################################################

sub HMCCUCHN_InitDevice ($$)
{
	my ($ioHash, $devHash) = @_;
	my $devspec = $devHash->{hmccu}{devspec};
	
	return 1 if (!HMCCU_IsValidChannel ($ioHash, $devspec, 7));

	my ($di, $da, $dn, $dt, $dc) = HMCCU_GetCCUDeviceParam ($ioHash, $devspec);
	return 1 if (!defined($da));

	# Inform HMCCU device about client device
	return 2 if (!HMCCU_AssignIODevice ($devHash, $ioHash->{NAME}));

	$devHash->{ccuif}       = $di;
	$devHash->{ccuaddr}     = $da;
	$devHash->{ccuname}     = $dn;
	$devHash->{ccutype}     = $dt;
	$devHash->{ccudevstate} = 'active';
	
	# Initialize user attributes
	HMCCU_SetSCAttributes ($ioHash, $devHash);

	if ($init_done) {
		# Interactive device definition
		HMCCU_AddDevice ($ioHash, $di, $da, $devHash->{NAME});
		HMCCU_UpdateDevice ($ioHash, $devHash);
		HMCCU_UpdateDeviceRoles ($ioHash, $devHash);
		
		my ($sc, $sd, $cc, $cd, $sdCnt, $cdCnt) = HMCCU_GetSCDatapoints ($devHash);
		
		HMCCU_UpdateRoleCommands ($ioHash, $devHash, $cc);
		HMCCU_UpdateAdditionalCommands ($ioHash, $devHash, $cc, $cd);

		if (!exists($devHash->{hmccu}{nodefaults}) || $devHash->{hmccu}{nodefaults} == 0) {
			if (!HMCCU_SetDefaultAttributes ($devHash)) {
				HMCCU_SetDefaults ($devHash);
			}
		}
		HMCCU_GetUpdate ($devHash, $da, 'Value');
	}

	return 0;
}

######################################################################
# Delete device
######################################################################

sub HMCCUCHN_Undef ($$)
{
	my ($hash, $arg) = @_;

	if (defined($hash->{IODev})) {
		HMCCU_RemoveDevice ($hash->{IODev}, $hash->{ccuif}, $hash->{ccuaddr}, $hash->{NAME});
	}
	
	return undef;
}

######################################################################
# Rename device
######################################################################

sub HMCCUCHN_Rename ($$)
{
	my ($newName, $oldName) = @_;
	
	my $clHash = $defs{$newName};
	my $ioHash = defined($clHash) ? $clHash->{IODev} : undef;
	
	HMCCU_RenameDevice ($ioHash, $clHash, $oldName);
}

######################################################################
# Set attribute
######################################################################

sub HMCCUCHN_Attr ($@)
{
	my ($cmd, $name, $attrname, $attrval) = @_;
	my $hash = $defs{$name};

	if ($cmd eq 'set') {
		return 'Missing attribute value' if (!defined($attrval));
		if ($attrname eq 'IODev') {
			$hash->{IODev} = $defs{$attrval};
		}
		elsif ($attrname eq 'statevals') {
			return 'Device is read only' if ($hash->{readonly} eq 'yes');
		}
		elsif ($attrname eq 'statedatapoint') {
			return "Datapoint $attrval is not valid" if ($init_done &&
				!HMCCU_IsValidDatapoint ($hash, $hash->{ccutype}, $hash->{ccuaddr}, $attrval, 1));
			$hash->{hmccu}{state}{dpt} = $attrval;
		}
		elsif ($attrname eq 'controldatapoint') {
			return "Datapoint $attrval is not valid" if ($init_done &&
				!HMCCU_IsValidDatapoint ($hash, $hash->{ccutype}, $hash->{ccuaddr}, $attrval, 2));
			$hash->{hmccu}{control}{dpt} = $attrval;
		}
	}

	HMCCU_RefreshReadings ($hash) if ($init_done);

	return undef;
}

######################################################################
# Set commands
######################################################################

sub HMCCUCHN_Set ($@)
{
	my ($hash, $a, $h) = @_;
	my $name = shift @$a;
	my $opt  = shift @$a // return 'No set command specified';
	my $lcopt = lc($opt);

	# Check device state
	return "Device state doesn't allow set commands"
		if (!defined($hash->{ccudevstate}) ||
			$hash->{ccudevstate} eq 'pending' || !defined($hash->{IODev}) ||
			($hash->{readonly} eq 'yes' && $lcopt !~ /^(\?|clear|config|defaults)$/) ||
			AttrVal ($name, 'disable', 0) == 1);

	my $ioHash = $hash->{IODev};
	my $ioName = $ioHash->{NAME};
	return ($opt eq '?' ? undef : 'Cannot perform set commands. CCU busy')
		if (HMCCU_IsRPCStateBlocking ($ioHash));

	# Get state and control datapoints
	my ($sc, $sd, $cc, $cd) = HMCCU_GetSCDatapoints ($hash);
	
	# Additional commands, including state commands
	my $cmdList = $hash->{hmccu}{cmdlist}{set} // '';

	# Some commands require a control datapoint
	if ($opt =~ /^(control|toggle)$/) {
		return HMCCU_SetError ($hash, -14) if ($cd eq '');
		return HMCCU_SetError ($hash, -8, $cd)
			if (!HMCCU_IsValidDatapoint ($hash, $hash->{ccutype}, $hash->{ccuaddr}, $cd, 2));
	}
	
	my $result = '';
	my $rc;

	# Log commands
	HMCCU_Log ($hash, 3, "set $name $opt ".join (' ', @$a))
		if ($opt ne '?' && (HMCCU_IsFlag ($name, 'logCommand') || HMCCU_IsFlag ($ioName, 'logCommand')));
	
	if ($lcopt eq 'control') {
		my $value = shift @$a // return HMCCU_SetError ($hash, "Usage: set $name control {value}");
		my $stateVals = HMCCU_GetStateValues ($hash, $cd, $cc);
		$rc = HMCCU_SetMultipleDatapoints ($hash,
			{ "001.$hash->{ccuif}.$hash->{ccuaddr}.$cd" => HMCCU_Substitute ($value, $stateVals, 1, undef, '') }
		);
		return HMCCU_SetError ($hash, HMCCU_Min(0, $rc));
	}
	elsif ($lcopt eq 'datapoint') {
		return HMCCU_ExecuteSetDatapointCommand ($hash, $a, $h, $cc, $cd);
	}
	elsif ($lcopt eq 'toggle') {
		return HMCCU_ExecuteToggleCommand ($hash, $cc, $cd);
	}
	elsif (exists($hash->{hmccu}{roleCmds}{set}{$opt})) {
		return HMCCU_ExecuteRoleCommand ($ioHash, $hash, 'set', $opt, $cc, $a, $h);
	}
	elsif ($opt eq 'clear') {
		return HMCCU_ExecuteSetClearCommand ($hash, $a);
	}
	elsif ($lcopt =~ /^(config|values)$/) {
		return HMCCU_ExecuteSetParameterCommand ($ioHash, $hash, $lcopt, $a, $h);
	}
	elsif ($lcopt eq 'defaults') {
		my $mode = shift @$a // 'update';
		$rc = HMCCU_SetDefaultAttributes ($hash, { mode => $mode, role => undef, ctrlChn => $cc });
		$rc = HMCCU_SetDefaults ($hash) if (!$rc);
		HMCCU_RefreshReadings ($hash) if ($rc);
		return HMCCU_SetError ($hash, $rc == 0 ? "No default attributes found" : "OK");
	}
	else {
		my $retmsg = "clear defaults:reset,update";
		if ($hash->{readonly} ne 'yes') {
			$retmsg .= ' config';
			my ($a, $c) = split(":", $hash->{ccuaddr});
			my $dpCount = HMCCU_GetValidDatapoints ($hash, $hash->{ccutype}, $c, 2);
			$retmsg .= ' datapoint' if ($dpCount > 0);
			$retmsg .= " $cmdList" if ($cmdList ne '');
		}
		# return AttrTemplate_Set ($hash, $retmsg, $name, $opt, @$a);
		return $retmsg;
	}
}

######################################################################
# Get commands
######################################################################

sub HMCCUCHN_Get ($@)
{
	my ($hash, $a, $h) = @_;
	my $name = shift @$a;
	my $opt = shift @$a // return 'No get command specified';
	my $lcopt = lc($opt);

	return undef if (!defined ($hash->{ccudevstate}) || $hash->{ccudevstate} eq 'pending' ||
		!defined ($hash->{IODev}));

	my $disable = AttrVal ($name, "disable", 0);
	return undef if ($disable == 1);	

	my $ioHash = $hash->{IODev};
	my $ioName = $ioHash->{NAME};

	return $opt eq '?' ? undef : 'Cannot perform get command. CCU busy'
		if (HMCCU_IsRPCStateBlocking ($ioHash));

	my $ccutype = $hash->{ccutype};
	my $ccuaddr = $hash->{ccuaddr};
	my $ccuif = $hash->{ccuif};
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	my ($sc, $sd, $cc, $cd) = HMCCU_GetSCDatapoints ($hash);

	# Additional commands, including state commands
	my $cmdList = $hash->{hmccu}{cmdlist}{get} // '';

	my $result = '';
	my $rc;

	# Log commands
	HMCCU_Log ($hash, 3, "get $name $opt ".join (' ', @$a))
		if ($opt ne '?' && $ccuflags =~ /logCommand/ || HMCCU_IsFlag ($ioName, 'logCommand')); 

	if ($lcopt eq 'datapoint') {
		my $objname = shift @$a // return HMCCU_SetError ($hash, "Usage: get $name datapoint {datapoint}");		
		return HMCCU_SetError ($hash, -8, $objname)
			if (!HMCCU_IsValidDatapoint ($hash, $ccutype, $ccuaddr, $objname, 1));

		$objname = $ccuif.'.'.$ccuaddr.'.'.$objname;
		($rc, $result) = HMCCU_GetDatapoint ($hash, $objname, 0);
		return $rc < 0 ? HMCCU_SetError ($hash, $rc, $result) : $result;
	}
	elsif ($lcopt eq 'deviceinfo') {
		my ($devAddr, undef) = HMCCU_SplitChnAddr ($ccuaddr);
		return HMCCU_ExecuteGetDeviceInfoCommand ($ioHash, $hash, $devAddr, $sc, $sd, $cc, $cd);
	}
	elsif ($lcopt =~ /^(config|values|update)$/) {
		my ($devAddr, undef) = HMCCU_SplitChnAddr ($ccuaddr);
		my @addList = ($devAddr, "$devAddr:0", $ccuaddr);	
		my $resp = HMCCU_ExecuteGetParameterCommand ($ioHash, $hash, $lcopt, \@addList);
		return HMCCU_SetError ($hash, "Can't get device description") if (!defined($resp));
		return HMCCU_DisplayGetParameterResult ($ioHash, $hash, $resp);
	}
	elsif ($lcopt eq 'paramsetdesc') {
		$result = HMCCU_ParamsetDescToStr ($ioHash, $hash);
		return defined($result) ? $result : HMCCU_SetError ($hash, "Can't get device model");
	}
	elsif (exists($hash->{hmccu}{roleCmds}{get}{$opt})) {
		return HMCCU_ExecuteRoleCommand ($ioHash, $hash, 'get', $opt, $cc, $a, $h);
	}
	else {
		my $retmsg = "HMCCUCHN: Unknown argument $opt, choose one of";
		$retmsg .= ' update:noArg deviceInfo:noArg config:noArg paramsetDesc:noArg values:noArg';	
		my ($a, $c) = split(":", $hash->{ccuaddr});
		my @dpList;
		my $dpCount = HMCCU_GetValidDatapoints ($hash, $hash->{ccutype}, $c, 1, \@dpList);	
		$retmsg .= ' datapoint:'.join(",",@dpList) if ($dpCount > 0);
		$retmsg .= " $cmdList" if ($cmdList ne '');
		
		return $retmsg;
	}
}


1;

=pod
=item device
=item summary controls HMCCU client devices for Homematic CCU2/3 - FHEM integration
=begin html

<a name="HMCCUCHN"></a>
<h3>HMCCUCHN</h3>
<ul>
   The module implements Homematic CCU channels as client devices for HMCCU. A HMCCU I/O device must
   exist before a client device can be defined. If a CCU channel is not found, execute command
   'get ccuConfig' in I/O device. This will synchronize devices and channels between CCU
   and HMCCU.
   </br></br>
   <a name="HMCCUCHNdefine"></a>
   <b>Define</b><br/><br/>
   <ul>
      <code>define &lt;name&gt; HMCCUCHN {&lt;channel-name&gt; | &lt;channel-address&gt;}
      [readonly] [<u>defaults</u>|noDefaults] [iodev=&lt;iodev-name&gt;]</code>
      <br/><br/>
      If option 'readonly' is specified no set command will be available. With option 'noDefaults'
      no default attributes will be set during interactive device definition. <br/>
      The define command accepts a CCU channel name or channel address as parameter.
      <br/><br/>
      Examples:<br/>
      <code>define window_living HMCCUCHN WIN-LIV-1 readonly</code><br/>
      <code>define temp_control HMCCUCHN BidCos-RF.LEQ1234567:1</code>
      <br/><br/>
      The interface part of a channel address is optional. Channel addresses can be found with command
	  'get deviceinfo &lt;CCU-DeviceName&gt;' executed in I/O device.<br/><br/>
	  Internals:<br/>
	  <ul>
	  	<li>ccuaddr: Address of channel in CCU</li>
		<li>ccudevstate: State of device in CCU (active/inactive/dead)</li>
		<li>ccuif: Interface of device</li>
	  	<li>ccuname: Name of channel in CCU</li>
		<li>ccurole: Role of channel</li>
		<li>ccusubtype: Homematic subtype of device (different from ccutype for HmIP devices)</li>
		<li>ccutype: Homematic type of device</li>
		<li>readonly: Indicates whether FHEM device is writeable</li>
		<li>receiver: List of peered devices with role 'receiver'. If no FHEM device exists for a receiver, the
		name of the CCU device is displayed preceeded by 'ccu:'</li> 
		<li>sender: List of peered devices with role 'sender'. If no FHEM device exists for a sender, the
		name of the CCU device is displayed preceeded by 'ccu:'</li> 
	  </ul>
   </ul>
   <br/>
   
   <a name="HMCCUCHNset"></a>
   <b>Set</b><br/><br/>
   <ul>
      <li><b>set &lt;name&gt; clear [&lt;reading-exp&gt;|reset]</b><br/>
         Delete readings matching specified reading name expression. Default expression is '.*'.
         Readings 'state' and 'control' are not deleted. With option 'reset' all readings
         and all internally stored device parameter values are deleted.
      </li><br/>
      <li><b>set &lt;name&gt; config [device|&lt;receiver&gt;] &lt;parameter&gt;=&lt;value&gt;[:&lt;type&gt;] [...]</b><br/>
         Set multiple config (parameter set MASTER) or link (parameter set LINKS) parameters.
         If neither 'device' nor <i>receiver</i> is specified, configuration parameters of
         current channel are set. With option 'device' configuration parameters of the device
         are set.<br/>
         If a <i>receiver</i> is specified, parameters will be set for the specified link.
         Parameter <i>receiver</i> is the name of a FHEM device of type HMCCUDEV or HMCCUCHN or
         a channel address or a CCU channel name. For FHEM devices of type HMCCUDEV the number 
         of the linked <i>channel</i> must be specified.<br/>
         Parameter <i>parameter</i> must be a valid configuration parameter.
         If <i>type</i> is not specified, it's taken from parameter set definition. If type 
         cannot be determined, the default <i>type</i> STRING is used.
         Valid types are STRING, BOOL, INTEGER, FLOAT, DOUBLE.<br/><br/>
         Example 1: Set device parameter AES<br/>
         <code>set myDev config device AES=1</code><br/>
         Example 2: Set channel parameters MIN and MAX with type definition<br/>
         <code>set myDev config MIN=0.5:FLOAT MAX=10.0:FLOAT</code><br/>
         Example 3: Set link parameter. DEV_PARTNER is a HMCCUDEV device, so channel number (3) is required<br/>
         <code>set myDev config DEV_PARTNER:3 MYPARAM=1</code>
      </li><br/>
      <li><b>set &lt;name&gt; control &lt;value&gt;</b><br/>
      	Set value of control datapoint. This command is available only on command line
      	for compatibility reasons. It should not be used any more.
      </li><br/>
      <li><b>set &lt;name&gt; datapoint &lt;datapoint&gt; &lt;value&gt; | &lt;datapoint&gt=&lt;value&gt; [...]</b><br/>
        Set datapoint values of a CCU channel. If value contains blank characters it must be
        enclosed in double quotes. This command is only available, if channel contains a writeable datapoint.<br/><br/>
        Examples:<br/>
        <code>set temp_control datapoint SET_TEMPERATURE 21</code><br/>
        <code>set temp_control datapoint AUTO_MODE 1 SET_TEMPERATURE=21</code>
      </li><br/>
      <li><b>set &lt;name&gt; defaults ['reset'|'<u>update</u>']</b><br/>
   		Set default attributes for CCU device type. Default attributes are only available for
   		some device types and for some channels of a device type. If option 'reset' is specified,
   		the following attributes are deleted before the new attributes are set: 
   		'ccureadingname', 'ccuscaleval', 'eventMap', 'substexcl', 'webCmd', 'widgetOverride'.
   		During update to version 4.4 it's recommended to use option 'reset'.
      </li><br/>
      <li><b>set &lt;name&gt; down [&lt;value&gt;]</b><br/>
      	[dimmer, blind] Decrement value of datapoint LEVEL. This command is only available
      	if channel contains a datapoint LEVEL. Default for <i>value</i> is 20.
      </li><br/>
      <li><b>set &lt;name&gt; on-for-timer &lt;ontime&gt;</b><br/>
         [switch] Switch device on for specified number of seconds. This command is only available if
         channel contains a datapoint ON_TIME. Parameter <i>ontime</i> can be specified
         in seconds or in format HH:MM:SS<br/><br/>
         Example: Turn switch on for 300 seconds<br/>
         <code>set myswitch on-for-timer 300</code>
      </li><br/>
      <li><b>set &lt;name&gt; on-till &lt;timestamp&gt;</b><br/>
         [switch] Switch device on until <i>timestamp</i>. Parameter <i>timestamp</i> can be a time in
         format HH:MM or HH:MM:SS. This command is only available if channel contains a datapoint
         ON_TIME. 
      </li><br/>
      <li><b>set &lt;name&gt; pct &lt;value&gt; [&lt;ontime&gt; [&lt;ramptime&gt;]]</b><br/>
         [dimmer] Set datapoint LEVEL of a channel to the specified <i>value</i>. Optionally a <i>ontime</i>
         and a <i>ramptime</i> (both in seconds) can be specified. This command is only available
         if channel contains at least a datapoint LEVEL and optionally datapoints ON_TIME and
         RAMP_TIME. The parameter <i>ontime</i> can be specified in seconds or as timestamp in
         format HH:MM or HH:MM:SS. If <i>ontime</i> is 0 it's ignored. This syntax can be used to
         modify the ramp time only.<br/><br/>
         Example: Turn dimmer on for 600 second. Increase light to 100% over 10 seconds<br>
         <code>set myswitch pct 100 600 10</code>
      </li><br/>
      <li><b>set &lt;name&gt; stop</b><br/>
      	[blind] Set datapoint STOP of a channel to true. This command is only available, if the
      	channel contains a datapoint STOP.
      </li><br/>
      <li><b>set &lt;name&gt; toggle</b><br/>
		Toggle state datapoint between values defined by attribute 'statevals'. This command is
		only available if state values can be detected or are defined by using attribute
		'statevals'. Toggling supports more than two state values.<br/><br/>
		Example: Toggle blind actor<br/>
		<code>
		attr myswitch statevals up:100,down:0<br/>
		set myswitch toggle
		</code>
      </li><br/>
      <li><b>set &lt;name&gt; up [&lt;value&gt;]</b><br/>
      	[blind,dimmer] Increment value of datapoint LEVEL. This command is only available
      	if channel contains a datapoint LEVEL. Default for <i>value</i> is 20.
      </li><br/>
      <li><b>set &lt;name&gt; values &lt;parameter&gt;=&lt;value&gt;[:&lt;type&gt;] [...]</b><br/>
      	Set multiple datapoint values (parameter set VALUES). Parameter <i>parameter</i>
      	must be a valid datapoint name. If <i>type</i> is not specified, it's taken from
         parameter set definition. The default <i>type</i> is STRING.
         Valid types are STRING, BOOL, INTEGER, FLOAT, DOUBLE.
      </li>
   </ul>
   <br/>
   
   <a name="HMCCUCHNget"></a>
   <b>Get</b><br/><br/>
   <ul>
      <li><b>get &lt;name&gt; config</b><br/>
		Get configuration parameters of device and channel.
		Values related to configuration or link parameters are stored as readings beginning
		with "R-" for MASTER parameter set and "L-" for LINK parameter set. 
		Prefixes "R-" and "L-" can be modified with attribute 'ccuReadingPrefix'. Whether parameters are
		stored as readings or not, can be controlled by setting the following flags in
		attribute ccuflags:<br/>
		<ul>
			<li>noReadings: Do not store any reading.</li>
			<li>showMasterReadings: Store configuration readings of parameter set 'MASTER' of current channel.</li>
			<li>showDeviceReadings: Store configuration readings of device and value readings of channel 0.</li>
			<li>showLinkReadings: Store readings of links.</li>
			<li>showServiceReadings: Store readings of parameter set 'SERVICE'</li>
		</ul>
		If non of the flags is set, only readings belonging to parameter set VALUES (datapoints)
		are stored.
      </li><br/>
      <li><b>get &lt;name&gt; datapoint &lt;datapoint&gt;</b><br/>
        Get value of a CCU channel datapoint. Format of <i>datapoint</i> is ChannelNo.DatapointName.
		For HMCCUCHN devices the ChannelNo is not needed. This command is only available if a 
		readable datapoint exists.
      </li><br/>
      <li><b>get &lt;name&gt; defaults</b><br/>
      	This command has been removed in version 4.4. The default attributes are included in the
		output of command 'get deviceInfo'.
      </li><br/>
      <li><b>get &lt;name&gt; deviceInfo</b><br/>
		Display information about device type and channels:<br/>
		<ul>
			<li>all channels and datapoints of device with datapoint values and types</li>
			<li>statedatapoint and controldatapoint</li>
			<li>device and channel description</li>
			<li>default attributes (if device is not supported by built in functionality)</li>
		</ul>
		The output of this command is helpful to gather information about new / not yet supported devices.
		Please add this information to your post in the FHEM forum, if you have a question about
		the integration of a new device. See also command 'get paramsetDesc'.
      </li><br/>
      <li><b>get &lt;name&gt; paramsetDesc</b><br/>
		Display description of parameter sets of channel and device. The output of this command
		is helpful to gather information about new / not yet supported devices. Please add this
		information to your post in the FHEM forum, if you have a question about
		the integration of a new device. See also command 'get deviceInfo'.
      </li><br/>
      <li><b>get &lt;name&gt; update</b><br/>
        Update all readings for all parameters of all parameter sets (MASTER, LINK, VALUES).
      </li><br/>
      <li><b>get &lt;name&gt; values</b><br/>
      	Update all readings for all parameters of parameter set VALUES (datapoints).
      </li><br/>
      <li><b>get &lt;name&gt; weekProgram [&lt;program-number&gt;|<u>all</u>]</b><br/>
      	Display week programs. This command is only available if a device supports week programs.
      </li>
   </ul>
   <br/>
   
   <a name="HMCCUCHNattr"></a>
   <b>Attributes</b><br/><br/>
   <ul>
      To reduce the amount of events it's recommended to set attribute 'event-on-change-reading'
      to '.*'.
      <br/><br/>
      <a name="calculate"></a>
      <li><b>ccucalculate &lt;value-type&gt;:&lt;reading&gt;[:&lt;dp-list&gt;[;...]</b><br/>
      	Calculate special values like dewpoint based on datapoints specified in
      	<i>dp-list</i>. The result is stored in <i>reading</i>. For datapoints in <i>dp-list</i>
      	also variable notation is supported (for more information on variables see documentation of
      	attribute 'peer').<br/>
      	The following <i>value-types</i> are supported:<br/>
      	dewpoint = calculate dewpoint, <i>dp-list</i> = &lt;temperature&gt;,&lt;humidity&gt;<br/>
      	abshumidity = calculate absolute humidity, <i>dp-list</i> = &lt;temperature&gt;,&lt;humidity&gt;<br/>
      	equ = compare datapoint values. Result is "n/a" if values are not equal.<br/>
      	inc = increment datapoint value considering reset of datapoint, <i>dp-list</i> = &lt;counter-datapoint&gt;<br/>
      	min = calculate minimum continuously, <i>dp-list</i> = &lt;datapoint&gt;<br/>
      	max = calculate maximum continuously, <i>dp-list</i> = &lt;datapoint&gt;<br/>
      	sum = calculate sum continuously, <i>dp-list</i> = &lt;datapoint&gt;<br/>
      	avg = calculate average continuously, <i>dp-list</i> = &lt;datapoint&gt;<br/>
      	Example:<br/>
      	<code>dewpoint:taupunkt:1.TEMPERATURE,1.HUMIDITY</code>
      </li><br/>
      <a name="ccuflags"></a>
      <li><b>ccuflags {ackState, logCommand, noReadings, showDeviceReadings, showLinkReadings, showConfigReadings, trace}</b><br/>
      	Control behaviour of device:<br/>
      	ackState: Acknowledge command execution by setting STATE to error or success.<br/>
      	logCommand: Write get and set commands to FHEM log with verbose level 3.<br/>
      	noReadings: Do not update readings<br/>
      	showDeviceReadings: Show readings of device and channel 0.<br/>
      	showLinkReadings: Show link readings.<br/>
      	showMasterReadings: Show configuration readings.<br/>
			showServiceReadings: Show service readings (HmIP only)<br/>
      	trace: Write log file information for operations related to this device.
      </li><br/>
      <a name="ccuget"></a>
      <li><b>ccuget {State | <u>Value</u>}</b><br/>
         Set read access method for CCU channel datapoints. Method 'State' is slower than 'Value'
         because each request is sent to the device. With method 'Value' only CCU is queried.
         Default is 'Value'.
      </li><br/>
      <a name="ccureadingfilter"></a>
      <li><b>ccureadingfilter &lt;filter-rule[;...]&gt;</b><br/>
         Only datapoints matching specified expression <i>RegExp</i> are stored as readings.<br/>
         Syntax for <i>filter-rule</i> is either:<br/>
         [N:]{&lt;channel-name-expr&gt;}!RegExp&gt; or:<br/>
         [N:][&lt;channel-number&gt;[,&lt;channel-number&gt;].]&lt;RegExp&gt;<br/>
         If <i>channel-name</i> or <i>channel-number</i> is specified the following rule 
         applies only to this channel.<br/>
         If a rule starts with 'N:' the filter is negated which means that a reading is 
         stored if rule doesn't match.<br/><br/>
         Examples:<br/>
         <code>
         attr mydev ccureadingfilter .*<br/>
         attr mydev ccureadingfilter 1.(^ACTUAL|CONTROL|^SET_TEMP);(^WINDOW_OPEN|^VALVE)<br/>
         attr mydev ccureadingfilter MyBlindChannel!^LEVEL$<br/>
         </code>
      </li><br/>
      <a name="ccureadingformat"></a>
      <li><b>ccureadingformat {address[lc] | name[lc] | datapoint[lc] | &lt;format-string&gt;}</b><br/>
         Set format of reading names. Default for virtual device groups and HMCCUCHN devices is 'name'.
         The default for HMCCUDEV is 'datapoint'. If set to 'address' format of reading names
         is channel-address.datapoint. If set to 'name' format of reading names is
         channel-name.datapoint. If set to 'datapoint' format is channel-number.datapoint.
         For HMCCUCHN devices the channel part is ignored. With suffix 'lc' reading names are converted
         to lowercase. The reading format can also contain format specifiers %a (address), 
         %n (name) and %c (channel). Use %A, %N, %C for conversion to upper case.<br/><br/>
         Example:<br/>
         <code>
         attr mydev ccureadingformat HM_%c_%N
         </code>
      </li><br/>
      <a name="ccureadingname"></a>
      <li><b>ccureadingname &lt;old-readingname-expr&gt;:[+]&lt;new-readingname&gt[,...];[;...]</b><br/>
         Set alternative or additional reading names or group readings. Only part of old reading
         name matching <i>old-readingname-exptr</i> is substituted by <i>new-readingname</i>.
         If <i>new-readingname</i> is preceded by '+' an additional reading is created. If 
         <i>old-readingname-expr</i> matches more than one reading the values of these readings
         are stored in one reading. This makes sense only in some cases, i.e. if a device has
         several pressed_short datapoints and a reading should contain a value if any button
         is pressed.<br/><br/>
         Examples:<br/>
         <code>
         # Rename readings 0.LOWBAT and 0.LOW_BAT as battery<br/>
         attr mydev ccureadingname 0.(LOWBAT|LOW_BAT):battery<br/>
         # Add reading battery as a copy of readings LOWBAT and LOW_BAT.<br/>
         # Rename reading 4.SET_TEMPERATURE as desired-temp<br/>
         attr mydev ccureadingname 0.(LOWBAT|LOW_BAT):+battery;1.SET_TEMPERATURE:desired-temp<br/>
         # Store values of readings n.PRESS_SHORT in new reading pressed.<br/>
         # Value of pressed is 1/true if any button is pressed<br/>
         attr mydev ccureadingname [1-4].PRESSED_SHORT:+pressed
         </code>
      </li><br/>
      <a name="ccuReadingPrefix"></a>
      <li><b>ccuReadingPrefix &lt;paramset&gt;:&lt;prefix&gt;[,...]</b><br/>
      	Set reading name prefix for parameter sets. Default values for parameter sets are:<br/>
			VALUES (state values): No prefix<br/>
			MASTER (configuration parameters): 'R-'<br/>
			LINK (links parameters): 'L-'<br/>
			PEER (peering parameters): 'P-'<br/>
			SERVICE (service parameters): S-<br/>
      </li><br/>
      <a name="ccuscaleval"></a>
      <li><b>ccuscaleval &lt;[channelno.]datapoint&gt;:&lt;factor&gt;[,...]</b><br/>
      <b>ccuscaleval &lt;[!][channelno.]datapoint&gt;:&lt;min&gt;:&lt;max&gt;:&lt;minn&gt;:&lt;maxn&gt;[,...]
      </b><br/>
         Scale, spread, shift and optionally reverse values before executing set datapoint commands
         or after executing get datapoint commands / before storing values in readings.<br/>
         If first syntax is used during get the value read from CCU is devided by <i>factor</i>.
         During set the value is multiplied by factor.<br/>
         With second syntax one must specify the interval in CCU (<i>min,max</i>) and the interval
         in FHEM (<i>minn, maxn</i>). The scaling factor is calculated automatically. If parameter
         <i>datapoint</i> starts with a '!' the resulting value is reversed.
         <br/><br/>
         Example: Scale values of datapoint LEVEL for blind actor and reverse values<br/>
         <code>
         attr myblind ccuscale !LEVEL:0:1:0:100
         </code>
      </li><br/>
      <a name="ccuSetOnChange"></a>
      <li><b>ccuSetOnChange &lt;expression&gt;</b><br/>
      	Check if datapoint value will be changed by set command before changing datapoint value.
      	This attribute can reduce the traffic between CCU and devices. It presumes that datapoint
      	state in CCU is current.
      </li><br/>
      <li><b>ccuverify {<u>0</u> | 1 | 2}</b><br/>
         If set to 1 a datapoint is read for verification after set operation. If set to 2 the
         corresponding reading will be set to the new value directly after setting a datapoint
         in CCU without any verification.
      </li><br/>
      <a name="controldatapoint"></a>
      <li><b>controldatapoint &lt;datapoint&gt;</b><br/>
         Set datapoint for device control by commands 'set control' and 'set toggle'.
         This attribute must be set if control datapoint cannot be detected automatically. 
      </li><br/>
      <a name="disable"></a>
      <li><b>disable {<u>0</u> | 1}</b><br/>
      	Disable client device.
      </li><br/>
      <a name="hmstatevals"></a>
		<li><b>hmstatevals &lt;subst-rule&gt;[;...]</b><br/>
         Define building rules and substitutions for reading hmstate. Syntax of <i>subst-rule</i>
         is<br/>
         [=&lt;reading&gt;;]&lt;datapoint-expr&gt;!&lt;{#n1-m1|regexp}&gt;:&lt;text&gt;[,...]
         <br/><br/>
         The syntax is almost the same as of attribute 'substitute', except there's no channel
         specification possible for datapoint and parameter <i>datapoint-expr</i> is a regular
         expression.<br/>
         The value of the I/O device attribute 'ccudef-hmstatevals' is appended to the value of
         this attribute. The default value of 'ccudef-hmstatevals' is
         '^UNREACH!(1|true):unreachable;LOW_?BAT!(1|true):warn_battery'.
         Normally one should not specify a substitution rule for the "good" value of an error
         datapoint (i.e. 0 for UNREACH). If none of the rules is matching, reading 'hmstate' is set
         to value of reading 'state'.<br/>
         Parameter <i>text</i> can contain variables in format ${<i>varname</i>}. The variable
         $value is substituted by the original datapoint value. All other variables must match
         with a valid datapoint name or a combination of channel number and datapoint name
         seperated by a '.'.<br/>
         Optionally the name of the HomeMatic state reading can be specified at the beginning of
         the attribute in format =&lt;reading&gt;;. The default reading name is 'hmstate'.
      </li><br/>
      <a name="peer"></a>
		<li><b>peer &lt;datapoints&gt;:&lt;condition&gt;:
			{ccu:&lt;object&gt;=&lt;value&gt;|hmccu:&lt;object&gt;=&lt;value&gt;|
			fhem:&lt;command&gt;}</b><br/>
      	Logically peer datapoints of a HMCCUCHN or HMCCUDEV device with another device or any
      	FHEM command.<br/>
      	Parameter <i>datapoints</i> is a comma separated list of datapoints in format
      	<i>channelno.datapoint</i> which can trigger the action.<br/>
      	Parameter <i>condition</i> is a valid Perl expression which can contain
      	<i>channelno.datapoint</i> names as variables. Variables must start with a '$' or a '%'.
      	If a variable is preceded by a '$' the variable is substituted by the converted datapoint
      	value (i.e. "on" instead of "true"). If variable is preceded by a '%' the raw value
      	(i.e. "true") is used. If '$' or '%' is doubled the previous values will be used.<br/>
      	If the result of this operation is true, the action specified after the second colon
      	is executed. Three types of actions are supported:<br/>
      	<b>hmccu</b>: Parameter <i>object</i> refers to a FHEM device/datapoint in format
      	&lt;device&gt;:&lt;channelno&gt;.&lt;datapoint&gt;<br/>
      	<b>ccu</b>: Parameter <i>object</i> refers to a CCU channel/datapoint in format
      	&lt;channel&gt;.&lt;datapoint&gt;. <i>channel</i> can be a channel name or address.<br/>
      	<b>fhem</b>: The specified <i>command</i> will be executed<br/>
      	If action contains the string $value it is substituted by the current value of the 
      	datapoint which triggered the action. The attribute supports multiple peering rules
      	separated by semicolons and optionally by newline characters.<br/><br/>
      	Examples:<br/>
      	# Set FHEM device mydummy to value if formatted value of 1.STATE is 'on'<br/>
      	<code>attr mydev peer 1.STATE:'$1.STATE' eq 'on':fhem:set mydummy $value</code><br/>
      	# Set 2.LEVEL of device myBlind to 100 if raw value of 1.STATE is 1<br/>
      	<code>attr mydev peer 1.STATE:'%1.STATE' eq '1':hmccu:myBlind:2.LEVEL=100</code><br/>
      	# Set 1.STATE of device LEQ1234567 to true if 1.LEVEL < 100<br/>
      	<code>attr mydev peer 1.LEVEL:$1.LEVEL < 100:ccu:LEQ1234567:1.STATE=true</code><br/>
      	# Set 1.STATE of device LEQ1234567 to true if current level is different from old level<br/>
      	<code>attr mydev peer 1.LEVEL:$1.LEVEL != $$1.LEVEL:ccu:LEQ1234567:1.STATE=true</code><br/>
		</li><br/>
		<a name="statedatapoint"></a>
      <li><b>statedatapoint &lt;datapoint&gt;</b><br/>
         Set datapoint used for displaying device state. This attribute must be set, if 
         state datapoint cannot be detected automatically.
      </li><br/>
      <a name="statevals"></a>
      <li><b>statevals &lt;text&gt;:&lt;text&gt;[,...]</b><br/>
         Define substitution for values of set commands. The parameters <i>text</i> are available
         as set commands.
         <br/><br/>
         Example:<br/>
         <code>
         attr my_switch statevals on:true,off:false<br/>
         set my_switch on
         </code>
      </li><br/>
      <a name="stripnumber"></a>
      <li><b>stripnumber [&lt;datapoint-expr&gt;!]{0|1|2|-n|%fmt}[;...]</b><br/>
      	Remove trailing digits or zeroes from floating point numbers, round or format
      	numbers. If attribute is negative (-0 is valid) floating point values are rounded
      	to the specified number of digits before they are stored in readings. The meaning of
      	values 0,1,2 is:<br/>
      	0 = Floating point numbers are stored as integer.<br/>
      	1 = Trailing zeros are stripped from floating point numbers except one digit.<br/>
   		2 = All trailing zeros are stripped from floating point numbers.<br/>
   		With %fmt one can specify any valid sprintf() format string.<br/>
   		If <i>datapoint-expr</i> is specified the formatting applies only to datapoints 
   		matching the regular expression.<br/>
   		Example:<br>
   		<code>
   		attr myDev stripnumber TEMPERATURE!%.2f degree
   		</code>
      </li><br/>
      <a name="substexcl"></a>
      <li><b>substexcl &lt;reading-expr&gt;</b><br/>
      	Exclude values of readings matching <i>reading-expr</i> from substitution. This is helpful
      	for reading 'control' if the reading is used for a slider widget and the corresponding
      	datapoint is assigned to attribute statedatapoint and controldatapoint.
      </li><br/>
      <a name="substitute"></a>
      <li><b>substitute &lt;subst-rule&gt;[;...]</b><br/>
         Define substitutions for datapoint/reading values. Syntax of <i>subst-rule</i> is<br/><br/>
         [[&lt;type&gt;:][&lt;channelno&gt;.]&lt;datapoint&gt;[,...]!]&lt;{#n1-m1|regexp}&gt;:&lt;text&gt;[,...]
         <br/><br/>
         Parameter <i>type</i> is a valid channel type/role, i.e. "SHUTTER_CONTACT".
         Parameter <i>text</i> can contain variables in format ${<i>varname</i>}. The variable 
         ${value} is
         substituted by the original datapoint value. All other variables must match with a valid
         datapoint name or a combination of channel number and datapoint name seperated by a '.'.
         <br/><br/>
         Example: Substitute the value of datapoint TEMPERATURE by the string 
         'T=<i>val</i> deg' and append current value of datapoint 1.HUMIDITY<br/>
         <code>
         attr my_weather substitute TEMPERATURE!.+:T=${value} deg H=${1.HUMIDITY}%
         </code><br/><br/>
         If rule expression starts with a hash sign a numeric datapoint value is substituted if
         it fits in the number range n &lt;= value &lt;= m.
         <br/><br/>
         Example: Interpret LEVEL values 100 and 0 of dimmer as "on" and "off"<br/>
         <code>
         attr my_dim substitute LEVEL!#0-0:off,#1-100:on
         </code>
      </li><br/>
      <a name="traceFilter"></a>
      <li><b>traceFilter &lt;filter-expr&gt;</b><br/>
      	Trace only function calls which are maching <i>filter-expr</i>.
      </li><br/>
   </ul>
</ul>

=end html
=cut

