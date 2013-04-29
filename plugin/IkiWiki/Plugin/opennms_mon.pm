#!/usr/bin/perl
# Ikiwiki skeleton plugin. Replace "skeleton" with the name of your plugin
# in the lines below, remove hooks you don't use, and flesh out the code to
# make it do something.
package IkiWiki::Plugin::opennms_mon;

use warnings;
use strict;
use IkiWiki 3.00;
use XML::Simple;
use Error qw(:try);
use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Request;
use HTTP::Response;
use IkiWiki::Plugin::osm;
use MIME::Base64::Perl;

use Data::Dumper;

sub import {
    hook(type => "getsetup", id =>"opennms_mon", call => \&getsetup);
    hook(type => "preprocess", id => "opennms_mon", call => \&preprocess);
    hook(type => "sessioncgi", id => "opennms_mon_nodelist", call => \&mon_nodelist);
    hook(type => "sessioncgi", id => "opennsm_mon_services", call => \&mon_services);
    hook(type => "sessioncgi", id => "opennsm_mon_node", call => \&mon_node);
}

sub getsetup() {
    return
	plugin => {
	    safe => 1,
	    rebuild => 0,
	    section => "special-purpose",
        },
	opennms_server_info => {
	    type => "string",
	    example => [
		'http://localhost:8980;YWRtaW46YWRtaW4=',
		'http://192.168.0.1:8980;dXNlcjpwYXNzd29yZA==',
	    ],
	    description => "URL and Base64 of username:password (separated by semi-colon) of all OpenNMS servers\n# See http://www.motobit.com/util/base64-decoder-encoder.asp for Base64 encoder",
	    safe => 0,
	    rebuild => 0,
	},
}

sub sanitizeSnmp (@) {
    my $str = shift;
    $str =~ s/-/_/;
    return $str;
}

sub removeDuplicates (@) {
    my @array = @_;
    return [] unless @array;
    my %hash = map { $_ => 1} @array;
    my @unique = keys %hash;
    return @unique;
}

sub sendRequest ($$;$) {
    my $serverInfo = shift;
    my $urlSuffix = shift;
    my $accept = shift || 'application/xml';

    my ($host, $userPass) = split(';', $serverInfo);
    my $url = $host . $urlSuffix;

    my $header = HTTP::Headers->new(Accept => $accept,
				    Authorization => "Basic $userPass",
	);
    my $request = HTTP::Request->new("GET", $url, $header);
    my $ua = LWP::UserAgent->new;
    my $response = $ua->request($request);

   if (!$response->is_success) {
	throw Error::Simple $response->status_line;
#	throw Error::Simple $url;
    }

    return $response;
}

sub preprocess (@) {
    my $html = "<a href=\"$config{cgiurl}?do=opennms_mon_nodelist\">Node list</a><br/>\n";
    $html .= "<a href=\"$config{cgiurl}?do=opennms_mon_services\">Nodes by service</a><br/>\n";

    return $html;
}

sub mon_nodelist (@) {
    my $cgi = shift;
    my $session = shift;

    return unless defined $cgi->param('do') &&
	$cgi->param("do") eq "opennms_mon_nodelist";

    my $html = "<ul>\n";

    my @nodes = getNodeListRest();
    foreach my $node (@nodes) {
	$html .= "\t<li>";
	my $nodeName = $node->getNodeName;
	my $id = $node->getId;
	$html .= "<a href=\"$config{cgiurl}?do=opennms_mon_node&node=$nodeName\">$nodeName</a>\n";
	$html .= "\t</li>\n"
    }

    $html .= "</ul>\n";

    IkiWiki::printheader($session);
    print IkiWiki::cgitemplate($cgi, "node list", $html);
    exit 0;
}

sub mon_services (@) {
    my $cgi = shift;
    my $session = shift;

    return unless defined $cgi->param('do') &&
	$cgi->param("do") eq "opennms_mon_services";

    my %services;
    try {
	my @nodes = getNodeListRest();
	foreach my $node (@nodes) {
	    foreach my $service ($node->getServices) {
		$services{$service} = [] unless $services{$service}; # initialize hash elements as arrays
		push(@{$services{$service}}, $node);
	    }
	}
    }
    catch Error::Simple with {
	my $ex = shift;
	error($ex->stringify());
    };

    my $html = "<ul>\n";
    foreach my $service (sort keys %services) {
	$html .= "\t<li>\n\t\t$service<br/>\n\t\t<pre>\n";
	foreach my $node (@{$services{$service}}) {
	    my $nodeName = $node->getNodeName;
	    my $id = $node->getId;
	    $html .= "<a href=\"$config{cgiurl}?do=opennms_mon_node&node=$nodeName\">$nodeName</a>\n";
	}
	$html .= "\t\t</pre>\n\t</li>\n";
    }
    $html .= "</ul>";

    IkiWiki::printheader($session);
    print IkiWiki::cgitemplate($cgi, "node list", $html);
    exit 0;
}

sub mon_node (@) {
    my $cgi = shift;
    my $session = shift;

    return unless defined $cgi->param('do') &&
	$cgi->param("do") eq "opennms_mon_node";

    my $nodeName = $cgi->param('node');
    if (!defined $nodeName) {
	error("Missing node name");
    }

    my $node = new Node($nodeName);

    my $html = "";
    my $response;
    my $xml;
    my $data;
    my $id = $node->getId;
    my $serverInfo = $node->getServerInfo;

    try {
	# Location
	$response = sendRequest($serverInfo, "/opennms/rest/nodes/$id");
	$xml = new XML::Simple;
	$data = $xml->XMLin($response->decoded_content);
	my $location = $data->{sysLocation};
	$html .= "SNMP Location: $location<br/>";

	# Status
	my $status = $node->isDown ? "Down" : "Up";
	$html .= "Status: $status<br/>";

	# IP
	my @ipAddresses;
	$html .= "IP: <pre>";
	foreach my $ipAddress ($node->getIpAddresses) {
	    $html .= "$ipAddress<br/>";
	}
	$html .= "</pre>";

	# MAC
	my @macAddresses;
	$html .= "MAC: <pre>";
	foreach my $macAddress ($node->getMacAddresses) {
	    my @macAddress = split("", $macAddress);
	    for (my $i = 0; $i < 10; $i += 2) {
		$html .= "$macAddress[$i]$macAddress[$i + 1]:"
	    }
	    $html .= "$macAddress[10]$macAddress[11]<br/>"
	}
	$html .= "</pre>";

	# Services
	$html .= "Services: <pre>";
	foreach my $service ($node->getServices) {
	    $html .= "$service<br/>";
	}
	$html .= "</pre>";

	# Map
	if ($location =~ /^\s*(\-?\d+(?:\.\d*°?|(?:°?|\s)\s*\d+(?:\.\d*\'?|(?:\'|\s)\s*\d+(?:\.\d*)?\"?|\'?)°?)[NS]?)\s*\,?\;?\s*(\-?\d+(?:\.\d*°?|(?:°?|\s)\s*\d+(?:\.\d*\'?|(?:\'|\s)\s*\d+(?:\.\d*)?\"?|\'?)°?)[EW]?)\s*$/) {
	    # If SNMP location is valid lat;lng, we display map at the location
	    my $pageName = "opennms_node/$nodeName";
	    my $mapCode = IkiWiki::Plugin::osm::preprocess(loc => $location,
							   right => "1",
							   width => "400px",
							   height => "400px",
							   page => $pageName,
							   destpage => $pageName
		);
	    $mapCode = IkiWiki::Plugin::osm::format(content => $mapCode,
						    page => $pageName,
		);
	    $html .= "\n$mapCode\n<br/>\n";
	}

	# Graphs
	my @graphs = getGraphs($node);
	if (@graphs) {
	    foreach my $graphData (@graphs) {
		$html .= "<img src=\"$graphData\" /><br/>\n";
	    }
	}
    }
    catch Error::Simple with {
	my $ex = shift;
	error($ex->stringify());
    };

    IkiWiki::printheader($session);
    print IkiWiki::cgitemplate($cgi, $nodeName, $html);

    exit 0;
}

sub nodeAlreadyInList($@) {
    # When using multiple OpenNMS servers, it is possible that a node is
    # listed by more than one server. To build our node list, we want to
    # avoid the same node twice. This function assumes that node names
    # are unique throughout the network.

    my $nodeName = shift;
    my @nodeList = @_;

    foreach my $node (@nodeList) {
	if ($node->getNodeName eq $nodeName) {
	    return 1;
	}
    }
    return 0;
}

sub getNodeListRest {
    my @nodeList;

    try {
	foreach my $serverInfo (@{$config{opennms_server_info}}) {
	    my $response = sendRequest($serverInfo, '/opennms/rest/nodes?limit=0');

	    my $xml = new XML::Simple;
	    my $data = $xml->XMLin($response->decoded_content, KeyAttr => {node => 'label'}, ForceArray => ['node']);
	    foreach my $nodeName (sort keys $data->{node}) {
		unless (nodeAlreadyInList($nodeName, @nodeList)) {
		    my $xmlNode = $data->{node}->{$nodeName};
		    my $id = $xmlNode->{id};
		    my $node = new Node($nodeName, $id, $serverInfo);
		    push(@nodeList, $node);
		}
	    }
	}
    }
    catch Error::Simple with {
	my $ex = shift;
	error($ex->stringify());
    };

    return @nodeList;
}

sub getAvailableGraphs (@) {
    # OpenNMS v 1.10 does not offer any way to get resource graphs via its
    # RESTful service. This function acquires the list of available graphs
    # by relying on the presentation layer (HTML) of the OpenNMS web app.
    # This leaves this function vulnerable to UI changes in the web app.
    # It should be rewritten should a the RESTful service offer a way to access
    # graphs in the future.
    my $node = shift;
    my $id = $node->getId;
    my $serverInfo = $node->getServerInfo;
    my @graphs;

    my $response= sendRequest($serverInfo, "/opennms/graph/chooseresource.htm?parentResourceType=node&parentResource=$id&reports=all");

    if (!$response->is_success) {
	throw Error::Simple $response->status_line;
    }

    my $html = $response->decoded_content;
    foreach my $rid ($html =~ m/id: \"(node\[$id\].[^\"]*)\"/g) {
	my $response= sendRequest($serverInfo, "/opennms/graph/results.htm?reports=all&resourceId=$rid");

	$html = $response->decoded_content;
	foreach my $graph ($html =~ m/src=\"graph\/graph\.png[^\?]*\?[^\&]*\&report=([^\&]*)&/g) {
	    push(@graphs, ($rid, $graph));
	}
    }
    return @graphs;
}

sub getGraphs (@) {
    my $node = shift;
    my $days = 1;
    my $end = time;
    my $start = $end - $days * 24 * 60 * 60;
    my @graphData;

    my @availableGraphs = getAvailableGraphs($node);

    for (my $i = 0; $i < @availableGraphs; $i += 2) {
	my $rid = $availableGraphs[$i];
	my $report = $availableGraphs[$i + 1];
	my $response= sendRequest($node->getServerInfo, "/opennms/graph/graph.png?resourceId=$rid&report=$report&start=$start&end=$end", "image/png");
	if (!$response->is_success) {
	    throw Error::Simple $response->status_line;
	}
	my $encodedImage = encode_base64($response->decoded_content);
	my $graphData = "data:image/png;base64,$encodedImage";
	push(@graphData, $graphData);
    }

    return @graphData;
}

sub Node::new($;$$) {
    my ($class, $nodeName, $id, $serverInfo) = @_;
    my $self;
    if (defined $id && defined $serverInfo) {
	# Real construction
	$self = {
	    _nodeName => $nodeName,
	    _id => $id,
	    _serverInfo => $serverInfo,
	};
    }
    else {
	# Get node from list of fully constructed nodes
	my @nodeList = getNodeListRest();
	foreach my $node (@nodeList) {
	    if ($node->getNodeName eq $nodeName) {
		$self = $node;
		last;
	    }
	}
    }

    bless $self, $class;
    return $self;
}

sub Node::completeConstruction {
    my $self = shift;

    unless ($self->{_id} && $self->{_serverInfo}) {
	my @nodeList = getNodeListRest();
	foreach my $node (@nodeList) {
	    if ($node->getNodeName eq $self->getNodeName) {
		$self->{_serverInfo} = $node->getServerInfo;
		last;
	    }
	}
    }
}

sub Node::getNodeName {
    my $self = shift;
    return $self->{_nodeName};
}

sub Node::getId {
    my $self = shift;
    return $self->{_id};
}

sub Node::getServerInfo {
    my $self = shift;
    return $self->{_serverInfo};
}

sub Node::getServices {
    my $self = shift;
    unless ($self->{_services}) {
	$self->{_services} = [];
	my $response;
	my $xml = new XML::Simple;
	my $data;
	my $id = $self->{_id};
	foreach my $ipAddress ($self->getIpAddresses) {
	    $response = sendRequest($self->getServerInfo, "/opennms/rest/nodes/$id/ipinterfaces/$ipAddress/services");
	    $data = $xml->XMLin($response->decoded_content, ForceArray => ['service']);
	    next unless exists $data->{service};
	    foreach my $service (keys $data->{service}) {
	    	push (@{$self->{_services}}, $data->{service}->{$service}->{serviceType}->{name});
	    }
	}
	# Remove duplicate services due to multiple IP's
	@{$self->{_services}} = removeDuplicates(@{$self->{_services}});
    }
    return @{$self->{_services}};
}

sub Node::getIpAddresses {
    my $self = shift;
    $self->_getIfData unless ($self->{_ipAddresses});
    return @{$self->{_ipAddresses}};
}

sub Node::getMacAddresses {
    my $self = shift;
    $self->_getIfData unless ($self->{_macAddresses});
    return @{$self->{_macAddresses}};
}

sub Node::getSnmpInterfaces {
    my $self = shift;
    unless ($self->{_snmpInterfaces}) {
	$self->{_snmpInterfaces} = [];
	my $id = $self->{_id};
	my $response = sendRequest($self->getServerInfo, "/opennms/rest/nodes/$id/snmpinterfaces");
	my $xml = new XML::Simple;
	my $data = $xml->XMLin($response->decoded_content, ForceArray => ['snmpInterface']);
	foreach my $snmpInterfaceData (keys $data->{snmpInterface}) {
	    my $snmpInterfaceXml = $data->{snmpInterface}->{$snmpInterfaceData};
	    next unless $snmpInterfaceXml->{collect} eq "1";
	    my $mac = $snmpInterfaceXml->{physAddr};
	    my $if = $snmpInterfaceXml->{ifName};
	    my $snmpInterface;
	    if (!defined $mac || length($mac) < 12) {
		$snmpInterface = $if;
	    }
	    else {
		$snmpInterface = "$if-$mac";
	    }
	    if ($snmpInterface) {
		push(@{$self->{_snmpInterfaces}}, sanitizeSnmp($snmpInterface));
	    }
	}
    }
    return @{$self->{_snmpInterfaces}};
}

sub Node::isDown {
    my $self = shift;
    unless ($self->{_isDown}) {
	my $id = $self->{_id};
	my $response = sendRequest($self->getServerInfo, "/opennms/rest/outages/forNode/$id");
	my $xml = new XML::Simple;
	my $data = $xml->XMLin($response->decoded_content);
	$self->{_isDown} = $data->{count} > 0 ? 1 : 0;
    }
    return $self->{_isDown};
}

sub Node::_getIfData {
    my $self = shift;

    $self->{_ipAddresses} = [];
    $self->{_macAddresses} = [];
    my $id = $self->{_id};
    my $response = sendRequest($self->getServerInfo, "/opennms/rest/nodes/$id/ipinterfaces");
    my $xml = new XML::Simple;
    my $data = $xml->XMLin($response->decoded_content, ForceArray => ['ipInterface']);
    foreach my $ipInterface (keys $data->{ipInterface}) {
	my $ipAddress = $data->{ipInterface}->{$ipInterface}->{ipAddress};
	my $macAddress = $data->{ipInterface}->{$ipInterface}->{snmpInterface}->{physAddr};
	push(@{$self->{_ipAddresses}}, $ipAddress);
	push(@{$self->{_macAddresses}}, $macAddress);
    }
};

1
