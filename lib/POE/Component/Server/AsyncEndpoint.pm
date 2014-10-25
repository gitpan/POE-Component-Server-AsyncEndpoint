package POE::Component::Server::AsyncEndpoint;

use warnings;
use strict;
our @EXPORT = ( );
use base qw(Exporter);
use vars qw($VERSION);
$VERSION = '0.01';


use POE;
use POE::Wheel::Run;
use POE::Component::IKC::Server;
use POE::Component::Server::AsyncEndpoint::Config;
use POE::Component::Server::AsyncEndpoint::Endpoints;
use POE::Component::Server::AsyncEndpoint::WebServer;
use POE::Component::Logger;
use POE::Component::MessageQueue;
use POE::Component::MessageQueue::Storage::Complex;

use Carp qw(croak);
use Data::Dumper;
use Switch;


autoflush STDOUT;

sub run {

    POE::Kernel->run();
    exit(0);

}

sub new {

    my $class = shift;
    my $args  = shift;

    # setup arguments
    my $alias;
    if ( ref($args) eq 'HASH' ){
        $alias    = $args->{alias};
    }

    # init server configuration
    my $config = POE::Component::Server::AsyncEndpoint::Config->init();

    # get endpoint filenames
    my @endpoints = POE::Component::Server::AsyncEndpoint::Endpoints->init();

    # init the web interface
    my $websrv = POE::Component::Server::AsyncEndpoint::WebServer->new({port => $config->webserver_port});

    # init the logger
    my $logger = POE::Component::Logger->spawn(
        ConfigFile => $config->aes_log_conf,
        Alias      => 'MAIN-Logger'
    );

    # Init the MQ Server
    my $mqsrv = POE::Component::MessageQueue->new({
        alias    => 'MQ-Master',
        port     => $config->aes_port,
        address  => $config->aes_addr,
        hostname => $config->aes_host,
        logger_alias => 'MAIN-logger',
        storage => POE::Component::MessageQueue::Storage::Complex->new({
            data_dir     => $config->mqdb_path,
            timeout      => $config->mqdb_timeout,
            throttle_max => $config->mqdb_throttle_max,
        }),
    });

    # name the session for master tasks
    unless ( defined $alias ){
        $alias = "AES-Master";
    }

    # AES Server Object
    my $self = {
        alias      => $alias,
        config     => $config,
        endpoints  => \@endpoints,
        websrv     => $websrv,
        logger     => $logger,
        mqsrv      => $mqsrv,
    };
    bless $self, $class;

    # The IKC Server
    POE::Component::IKC::Server->spawn(
        address => $self->{config}->aes_ikc_addr,
        port => $self->{config}->aes_ikc_port,
        name => "IKCS",
    );


    # AES Server Session
    POE::Session->create(
        inline_states => {
            _start => sub {
                my ($kernel, $heap) = @_[KERNEL, HEAP];
                $kernel->alias_set("$alias");
                $kernel->alias_set('AES_SESSION');
                $heap->{self} = $self;
                $kernel->yield('initep');
                $kernel->post('IKC', 'publish', 'AES_SESSION', ['logit']);
            },

            initep => \&init_endpoints,
            stdout => \&endpoint_stdout,
            stderr => \&endpoint_stderr,
            chld => sub {
                # signal handler for reaping of PID
                $_[KERNEL]->post(
                    'MAIN-Logger',
                    'debug',
                    "DEBUG: CHLD Signal Handler for PID:".$_[ARG1]."\n"
                );
            },
            chdead => \&child_dead,
            chdeadx => \&endpoint_dead,
            chwdg => \&endpoint_wdog,
            shutdown => \&shut_down_start,
            shutdown_complete => \&shut_down_complete,
            stop_endpoints => \&stop_endpoints,
            ikc_return => \&ikc_return,
            logit => \&ikc_return,
        },
    );

    POE::Kernel->post('MAIN-Logger', 'alert', "AES Initialize complete, ready to run.\n");

    return $self;

}


sub init_endpoints {

    my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

    my $self = $heap->{self};

    $kernel->post('MAIN-Logger', 'alert', "Initializing endpoints...\n");

    # setup signal handler
    $kernel->sig(CHLD => 'chld');

    foreach my $ep (@{$self->{endpoints}}){
        my $name = $ep->{pname};
        $ep->{wheel} = &new_wheel($name);
        $ep->{stat} = EP_STAT_OK;

        my $wid = $ep->{wheel}->ID;
        my $pid = $ep->{wheel}->PID;

        $kernel->post('MAIN-Logger', 'alert', "Started EP: $name in wheel id: $wid and PID: $pid\n");

    }

    # reset watchdog
    $kernel->delay_set('chwdg', $self->{config}->aes_cwdg);


}


# an endpoint said something
sub ikc_return {
    my ($heap, $kernel, $input) = @_[HEAP, KERNEL, ARG0];

    my $self = $heap->{self};

    my ($cmd, $pid, $msg) = split /\|/,$input;

    # log any strage STDOUT from endpoints in debug mode
    $kernel->post('MAIN-Logger', 'debug', "Enpoint with PID $pid returned IKC call with: $input\n");

    # Simple Endpoint Protocol via IKC
    switch($cmd){

        case "CASTAT" {

            my $newstat = EP_STAT_FA;

            if($msg eq "OK"){
                # watchdog blurb is notice level
                $kernel->post(
                    'MAIN-Logger',
                    'notice',
                    "Enpoint with PID $pid is OK\n"
                );
                $newstat = EP_STAT_OK;
            }

            if($msg eq "FAIL"){
                # watchdog blurb is notice level
                $kernel->post(
                    'MAIN-Logger',
                    'notice',
                    "Enpoint with PID $pid is alive but in FAIL state\n"
                );
            }

            # find the endpoint and reset status
            foreach my $ep (@{$self->{endpoints}}){
                my $wheel = $ep->{wheel};

                if($wheel->PID == $pid){
                    $ep->{stat} = $newstat,
                    $ep->{retries} = 0;
                }

            }

        }

        # log from IKC from EP
        case "LOGIT" {

            my ($log_level, $log_msg) = split /\;;/,$msg;

            $kernel->post('MAIN-Logger', $log_level, $log_msg);

        }

    }

}


# Log STDERR messages high
sub endpoint_stderr {
    my ($heap, $kernel, $input, $wheel_id) = @_[HEAP, KERNEL, ARG0, ARG1];
    $kernel->post('MAIN-Logger', 'alert', "ERROR: Enpoint in wheel $wheel_id wrote to STDERR: $input\n");
}

# Log STDOUT messages high
sub endpoint_stdout {
    my ($heap, $kernel, $input, $wheel_id) = @_[HEAP, KERNEL, ARG0, ARG1];
    $kernel->post('MAIN-Logger', 'alert', "ERROR: Enpoint in wheel $wheel_id wrote to STDOUT: $input\n");
}



# sets failed condition to endpoint
sub child_dead {
    my ($kernel, $heap, $wheel_id) = @_[KERNEL, HEAP, ARG0];

    my $self = $heap->{self};

    foreach my $ep (@{$self->{endpoints}}){

        if($ep->{wheel}->ID == $wheel_id){

            my $pid = $ep->{wheel}->PID;
            $kernel->post('MAIN-Logger', 'alert', "WARNING: Set FAIL on EP of dead child wheel id:$wheel_id PID: $pid\n");

            # set EP to FAIL status
            $ep->{stat} = EP_STAT_FA;
            $ep->{retries} = 0;

        }

    }

    # delayed EP restart procedure
    $_[KERNEL]->delay_set('chdeadx',$self->{config}->aes_rstc,$_[ARG0]);

}

# Cleans the old wheel and starts a fresh endpoint in it's place. This
# sub is delayed (see main AES session) because the endpoint could be
# dying emmediately and hogging the whole system in an infinite loop.
sub endpoint_dead {

    my ($kernel, $heap, $wheel_id) = @_[KERNEL, HEAP, ARG0];

    my $self = $heap->{self};

    $kernel->post('MAIN-Logger', 'debug', "IN endpoint_dead\n");

    # find the wheel and restart endpoint
    foreach my $ep (@{$self->{endpoints}}){

        my $wheel = $ep->{wheel};
        my $pname = $ep->{pname};

        if($wheel->ID == $wheel_id){

            # log and restart the child; replace the old ref so the old
            # wheel should be free for gc at this point
            $ep->{wheel} = &new_wheel($pname);
            $ep->{stat} = EP_STAT_OK;

            $kernel->post(
                'MAIN-Logger', 
                'alert', 
                "ALERT: Restarting EP: $pname in wheel ".
                $ep->{wheel}->ID." with new PID:".$ep->{wheel}->PID."\n");
        }

    }

}

sub new_wheel {

    my $pname = shift;

    my $wheel = POE::Wheel::Run->new(
        Program => $pname,
        StdoutEvent => 'stdout',
        StderrEvent => 'stderr',
        CloseEvent => 'chdead',
    );

    return $wheel;

}


sub endpoint_wdog {

    my ($kernel, $heap) = @_[KERNEL, HEAP];

    my $self = $heap->{self};

    # watchdog blurb is notice level
    $kernel->post('MAIN-Logger', 'notice', "EPWDG: --- ENTERING Endpoint Watchdog ---\n");

    foreach my $ep (@{$self->{endpoints}}){

        my $wheel   = $ep->{wheel};
        my $name    = $ep->{name};
        my $pname   = $ep->{pname};
        my $retries = \$ep->{retries};
        my $stat    = \$ep->{stat};
        my $pid     = $wheel->PID;

        $$retries++;

        # debug
        $kernel->post('MAIN-Logger', 'debug', "$pname RETRIES: $$retries STATUS:$$stat\n");

        # time to kill non-answering process
        if(
            ($$retries > $self->{config}->aes_wdgr) and
            ($$stat == EP_STAT_WA)
        ){
            # TODO: probable portability issue to non-unix
            # systems. Not a prority for me right now, but a helping
            # hand on non-unix machine is very welcome indeed.

            # this blurb is surely critical
            my $wid = $wheel->ID;
            $kernel->post(
                'MAIN-Logger', 
                'alert',
                "------------------------------------------------------------\n".
                "WATCHDOG ALERT: The Watchdog has been forced to kill process\n".
                "with PID: $pid on wheel id: $wid, because it never answered\n".
                "to STAT requests. EP Name: $pname\n".
                "------------------------------------------------------------\n"
            );

            # set EP to FAIL status
            $$stat = EP_STAT_FA;
            $$retries = 0;

            # signal the child to die
            $wheel->kill($SIG{KILL});

        }
        else {
            # request for status once again
            $$stat = EP_STAT_WA;
            $kernel->post( 'IKC', 'call', 'poe://'.$wheel->PID.'_IKCC/CA_SESSION/aesstat', undef, 'poe:ikc_return' );
        }

    }

    # this watchdog blurb is debug level
    $kernel->post('MAIN-Logger', 'debug', "EPWDG: --- LEAVING Endpoint Watchdog ---\n");

    # reset watchdog
    $kernel->delay_set('chwdg', $self->{config}->aes_cwdg, $self);

}


sub stop_endpoints {

    my ($heap, $kernel) = @_[HEAP, KERNEL];

    # TODO!!!

    # kill all wheels and remove references
    #foreach(0..$#{$self->{endpoints}}){

        #$self->{wheels}->[$_]->kill();
        #$self->{wheels}->[$_] = undef;
    #}

    #$self->{wheels} = undef;

}

sub shut_down_start {

    my ($kernel, $session) = @_[KERNEL, SESSION];


}


sub shut_down_complete {

    my ($kernel, $session) = @_[KERNEL, SESSION];


}

# Syslog debug levels
#0 debug
#1 info
#2 notice
#3 warning
#4 error
#5 critical
#6 alert
#7 emergency




1;

__END__


=head1 NAME

POE::Component::Server::AsyncEndpoint - Asynchronous Endpoint Server for EAI

=head1 SYNOPSIS

  1) Create the server and your endpoints:

  shell$ mkdir MyAES; cd MyAES; aescreate
  shell$ cd endpoints/
  shell$ endpointcreate

  Follow the prompts! (read on for full explanation)

  2) Configure the server and develop the endpoint code
  see POE::Component::Server::AsyncEndpoint::ChannelAdapter

  3) Run or daemonize the server
  shell$ ./aes &

  4) Monitor the server using the Web Interface or SNMP
    (Web and SNMP are being completed for the 0.02 release)

=head1 DESCRIPTION

=head2 About the term AES

Please note that we may at times abbreviate this project as AES
(Asynchronous Endpoint Server), and other times we may use "AES" to
refer to the master AES process. It should be clear by context when
we use it for one or the other.

=head2 Library or Platform?

More than a library, is a ready-to-use and complete SOA Application
Integration Platform. Once installed, you will use the helper scripts
to generate your server and message endpoints. These scripts will
scaffold most of the code and configuration files for you and all you
have to do is implement the code and your interface will be running in
a few minutes. It is also a CPAN library of course, which can be
easily extended and specialized to develop new software.

The initial motivation to develop this library was to facilitate the
deployment of B<asynchronous (non-blocking) outbound soap services>,
but we decided to build a complete end-to-end integration platform
that would be scalable and very easy to implement. It is not targeted
at the expert hacker, but rather to the integration consultant who
wants to get the job done, fast and easy.

The "Asynchronous Endpoint Server" implements a design pattern to aid
in the development and deployment of a B<distributed> (as opposed to
the centralized spirit of the so-called "Enterprise Service Bus" or
B<ESB>) Service Oriented Architecture (B<SOA>). The concepts and terms
come from several sources, but the actual names of the components are
inspired by the book "Enterprise Integration Patterns" by Gregor Hohpe
and Bobby Wolf (L<http://www.enterpriseintegrationpatterns.com>). The
AsyncEnpoint Server implements a component called a "Message Endpoint"
based on the specialization of the "Channel Adapter" concept coined in
the book, plus a series of helpers and facilities to deploy your
interface in just a few hours.

=head2 Current Protocol Support

At the moment, the Channel Adapters have out of the box support for
SOAP on the WS side and STOMP on the MQ side. More protocols can be
easily added by specializing the ChannelAdpater class. We hope to
receive feedback and incorporate new protocols as needed by the
user community.


=head2 Is this an Enterprise Service Bus?

To date, there is certain controversy on whether SOA should be
implemented in a B<hub-and-spoke> versus a B<bus> fashion, and it
seems that the "Enterprise Service Bus" is gaining some traction in
the "Enterprise" and also in the Free and Open Source Communities.

B<This project is the contrary of the bus pattern and promotes a more
distributed architecture where "the ESB (if it exists) is pushed to
the endpoints"> (quote from Dr. Jim Webbers's "Guerrilla SOA"
presentation Jim.Webber@ThoughtWorks.com L<http://jim.webber.name>).

=head2 In a Nutshell

Basically, you start by generating a server with the B<aescreate>
helper script (inside a pre existing empty directory). This will
create a directory structure, configuration files, and the aes
executable. To create a new Endpoint, you invoke the B<endpointcreate>
helper script (inside the B<endpoints> directory) and it will generate a
directory for the endpoint and scaffolding code. The B<endpointcreate>
will ask you a few questions and all you have to do is follow the
prompts.

Once you have your Endpoint code ready, you run the master B<aes>
executable and it, will in turn scan your directory structure and
start your endpoints automatically. The watchdog in the B<aes> will
monitor your Endpoints and re-start them if they should die for some
reason.

Each Endpoint is a distinct executable and will run as a separate PID
on your machine. This means that to a certain degree, you can develop
and debug your Endpoint code individually, although you won't have
access to the Message Queue server provided by the main aes
process. We hope to get some feedback on how we can further facilitate
the individual development of the Endpoints, perhaps by simulating the
MQ and other parts of the system. In the mean time, you may just
comment the things that rely on the B<aes> process. There is a
conceived facility to allow each Endpoint to be started and stopped
via a web interface, but this feature is currently under
development. At the moment, the aes master process will automatically
try to restart each endpoint unless you rename the executable to
something else. These limitations should disappear in the next release.


=head3 Programming Style

The programming technique is event-based (EDA) using POE (Perl Object
Environment) so you should have some familiarity with POE before
coding your Endpoints. Nevertheless, the scaffolding already generates
typical endpoint skeletons for you, so you don't have to be an expert
in POE.


=head3 Inbound (IB) and Outbound (OB) Endpoints

When creating and Endpoint you must chose between an IB or OB Endpoint
base. The OB Endpoint is designed to poll an OB Web Service (SOAP at
the moment) and publish the OB data to the MQ. The IB Endpoints
subscribe to an MQ and push to the target system via an IB Web Service
(SOAP at the moment).

The OB endpoints can be single or double phased. Please read the
"Poling or Event Driven Endpoints" subsection below for some important
information on the OB Endpoint design and considerations.

=head3 Poling or Event Driven Endpoints

To implement a B<non-blocking outbound> interface for any application,
you must somehow signal the outbound event to the destination
process. To guarantee that the signal delivery is non-blocking, this
signal must not depend on instantaneous acknowledgement of any other
process, and at the same time, the signal must not be lost. The most
obvious way to do this is to store the signal into permanent storage
for later retrieval by the destination process, and usually, you would
want to store these outbound signals in a database table or to a file
on disk.

Retrieving the signals from permanent storage requires either a
polling technique, or an event-based interface to the database table
or file (via a db trigger, or something in the likes of
POE::Wheel::FollowTail). Access to the table or file requires a
database connection or physical access to the file (locally or via the
network) which can be a security risk for many set-ups. Most systems
administrators do not want to deal with complicated set-ups, opening
arbitrary IP ports, etc. And also, she would want the flexibility to
run the interface on any server, not on one particular server.

For all these reasons, we assumed in our design that ALL interaction
with the business systems on ALL ends are STRICTLY through the use of
a Web Service, and for our first deployment, we have chosen SOAP over
HTTP transport. If you need something different, you can either extend
our classes, write us, or send us a patched version of your
extension. In any case, please contact the mailing list to discuss the
needs of your particular implementation.

From the above reasoning, the OB Endpoint must periodically invoke a
Web Service that retrieves the outbound signals from the source
system's permanent storage (in other words, B<polling> the "signals"
file with a Web Service). We call this "signals" file a B<FIFO> and
the Web Service that reads it, is called the B<FIFO Popper>. B<The
FIFO must never be confused or treated like a Message Queue>. The FIFO
is just a temporary stack to make the outbound signals non-blocking
and allow for the B<complete application interface> to be developed
through Web Services.

=head4 Single or Double Phased OB Endpoint

The OB Endpoint can be single-phased, double-phased or multi-phased
depending on the complexity ("orchestration", "choreography") and
business needs of each particular interface.

In the single-phased OB Endpoints, the FIFO record by itself contains
all the data needed to be pushed to the other system. This is
practical for simple interfaces such as passing document states
between two systems, or synchronizing master-slave value list data
between two databases. So if the data is not too complex, or you don't
need any complex "orchestration" or "choreography" it is usually best
to implement a single-phased OB Endpoint.

Double-phased OB Endpoints are needed when it's not practical or
feasible to save the OB data into the FIFO table or file directly. For
example, an interface that needs to send a complex document from one
system to the other (usually a complex document, will have multiple
parts, and you might also need to send some dependant data like
foreign key records). In these cases, the FIFO record will probably
just have the id of the document, and then another larger and complex
WS will actually construct the OB data package in a second phase.

The standard OB Endpoints generated by the helper scripts will let you
choose between single-phased or double-phased. Multi-phased are
implementation dependant and should be based on the double-phased type.

==head2 Technical Details

The idea of this section is that you can quickly understand the
library code and help us make this project better by hacking it and
sending us reviews and patches. We would very much welcome comments
and ideas on the code and most importantly, if you can send us
references on how you are using it would be excellent also.

As you can tell by the name-space,
POE::Component::Server::AsyncEndpoint resides in the Server components
of POE. This means that is mostly ready to use, and large part of the
code is actually based on other Components of POE and of CPAN in
general (please note that we use POE::Component and the abbreviated
form "PoCo" from this point on).

For the experienced Perl hacker, you may find that our wrappers over
some POE or CPAN components are too restrictive (pre-defined POE Alias
pre and suffixes, for example) and that some of our classes will
refuse to start and will croak if not implemented correctly. This is
actually done on purpose since this library is targeted for the final
user, and we reduce some flexibility to also reduce the pain. Any
comments are, of course, very welcome on the mailing list.

Some of the main packages that we build upon for the main server are:

        POE
        POE::Wheel::Run
        POE::Component::Logger
        POE::Component::MessageQueue
        POE::Component::Server::HTTP
        POE::Component::Server::SNMP (planned for release 0.02)

Basically, the AsyncEndpoint Server spawns a PoCo::MessageQueue
session and then scans the directory structure to find and run the
individual Endpoints via the package
PoCo::Server::AsyncEndpoint::Endpoints. The package
PoCo::Server::AsyncEndpoint::Config provides the configuration
facilities and PoCo::Server::AsyncEndpoint::WebServer provides the Web
Interface, which in turn is an implementation of
POE::Component::Server::HTTP.

B<NOTE for Version 0.01: The Web facility is still crude and the SNMP is
planned for 0.02 which should be released in by mid or late February
2008.>

The Endpoints are based on the class
PoCo::Server::AsyncEndpoint::ChannelAdapter which in turn implements
other POE components such as:

        SOAP::Lite (for SOAP support)
        POE::Component::Client::Stomp (for STOMP support)

Through these wrappers respectively:

        POE::Component::Server::AsyncEndpoint::ChannelAdapter::SOAP
        POE::Component::Server::AsyncEndpoint::ChannelAdapter::Stomp

It also provides a configuration file interface through

        POE::Component::Server::AsyncEndpoint::ChannelAdapter::Config

The AES starts the Endpoints with POE::Wheel::Run and communicates with
them via POE IKC on a predefined port. So the endpoints wind up
"speaking" three different languages: SOAP to communicate with the Web
Services, STOMP (L<http://stomp.codehaus.org/>) to communicate with
the MQ and SEP (Simple Endpoint Protocol) to communicate with the main
server process (via IKC). Endpoint programmers need not know about the
IKC and associated SEP protocol, as this is encapsulated in the
ChannelAdapter superclass.

Functionally, the Outbound (OB) Endpoints invoke a Web Service and
push the data using STOMP to the MQ Server. The IB Endpoints, on the
other hand, subscribe to the channels and push the incoming data
through a Web Service on their side. So in a nutshell, the AES as a
whole is a platform to link systems that offer plain SOAP services,
with an emphasis on easily implementing asynchronous outbound SOAP
services.

=head3 Event and Process Model

The publishing of SEDA (Matt Welsh 2001) raised many polemic
discussions on whether EDA is better than thread/process model and
others. We think that each one has it's benefits so we opted for a
"Salomonic" solution: Each Endpoint is an Operating System Process,
but the programming technique of the Endpoint code is EDA (thanks to
POE).


=head2 CAVEATS

The OB Endpoint must coded in such a way, that it can only handle ONE
FIFO RECORD at any given time, and should not mark the FIFO record as
"POPPED", until the endpoint gets a STOMP/RECEIPT. This way, you don't
have to handle stacks or queues in your code and place all
responsibility on the MQ, where it should be. In the IB Endpoint, you
should not STOMP/ACK the message until you have made sure that the IB
Web Service has succeeded. The stub code generated by the helper
scripts try to enforce these practices, but ultimately it's up to the
final programmer to follow them.

Note that an obvious weak link is if the OB Endpoint process dies right
after getting the STOMP RECEIPT and before the invocation of the
POPPED Web Service (the one that marks the FIFO record as effectively
popped). Also, if the POPPED Web Service is failing in any way, as
long as you don't shutdown the Endpoint, it you should make sure not
to process any more FIFO records until you can successfully mark the
current one as POPPED (i.e. you get some-kind of OK from your Web
Service). We are currently evaluating all borderline conditions an
will not only develop automated tests for each one, but will also work
on a safe shutdown sequence that warns about these conditions.

Even with all these precautions, if the OB Endpoint dies, or the
POPPED Service never recovers before a re-start of the endpoint, this
will result in a duplicate message down the MQ, so B<please take this
into account>. Unless you are processing B<TRANSACTIONS> (GL entries,
for example) all this should not worry you too much. If you do process
transactions, the use of a correlative and/or distinct id, might aid
to reduce or effectively eliminate the possibility of duplicate
records on the target system. Some interfaces rely on the concept of
master and slave tables, where the unique identifiers of the slave
tables are always re-written by the owner of the record (the
Master). The good news is that the way this library is written (and if
you follow all the recommendations) you should never lose events, on
the contrary, the problem is actually the possibility of duplication
as stated above, which can easily be solved with unique identifiers
and good coding of the Web Services themselves. Please discuss your
specific needs on the list so we can work on these issues.

In any case, the use of serial id's should always be preferred over
the use of alpha-numeric identifiers for records, so FIFO tables and
files, should have a serial id column always (this is regardless of
the "logic" correlative that you may have for transaction based
FIFOs). The examples and the generated stub code already set-up many
of these practices for you.

==head3 Using XML for the actual Message Data

Even though traditionally, most Web Services use XML for the
serialization of data, we have found that using XML is, in many cases,
a useless overhead and an unnecessary complication. The use of simple
and universal serialization languages, such as JSON, is a great
alternative for many interfaces. Of course, you use still have to use
XML B<to define> the WS (and for the SOAP envelope), but the actual
data (the "message parts" in WSDL) are just XSD::string (JSON encoded
strings) that carry associative arrays and perhaps even simple
objects. All our examples use this technique, but of course, it's up
to you if you want to use XML or another serialization technique. In
the Perl world, the Dumper format or YAML would probably be preferred,
but JSON is widely available out-of-the-box on popular languages like
(JavaScript and PHP), making it perhaps a bit more universal. In any
case, any of these techniques will be lighter and more practical than
XML for most data exchange needs.

==head3 Encoding

We assume that all interface components as well as the Web Services
that provide the data use UTF-8 encoded information. Support for other
encoding systems is up to the developer, but please discuss it on the
list if you require a different one and it's not working.

=head2 OPERATING SYSTEM SUPPORT

The system has been developed and tested on Linux. We should say that
it runs everywhere that Perl runs but we don't have the resources or
the need for it to run outside of Linux and FreeBSD (or most Unix or
Unix-like OSs). Testing and portability issues to other platforms may
be an added bonus in the future, and if anyone needs this to run in a
non-UNIX platform please let us know. In general, we think that should
run anywhere POE runs, but we can't be sure. Send us your comments and
we will do our best to help.

=head2 COMMUNITY SUPPORT

This software is part of the P2EE project (L<http://www.p2ee.org>) and
can be directly discussed on the p2ee development mailing list here:
L<https://lists.sourceforge.net/lists/listinfo/p2ee-devel>.

=head2 COMMERCIAL SUPPORT

Corcaribe Tecnología C.A. (L<http://www.corcaribe.com>) has funded
this particular development and provides commercial support and
enhancements to this software. In general Corcaribe will ask that any
generalized enhancements be fed back to the original project(s) and to
the Perl Community in general.

=head2 EXPORT

None by default.

=head1 SEE ALSO

L<POE::Component::Server::AsyncEndpoint::ChannelAdapter>
L<POE::Component::Server::AsyncEndpoint::ChannelAdapter::SOAP>
L<POE::Component::Server::AsyncEndpoint::ChannelAdapter::Stomp>
L<POE::Component::Server::AsyncEndpoint::ChannelAdapter::Config>

L<POE>
L<POE::Wheel::Run>
L<POE::Component::Logger>
L<POE::Component::MessageQueue>
L<POE::Component::Server::HTTP>
L<POE::Component::Server::SNMP>
L<SOAP::Lite>
L<POE::Component::Client::Stomp>
L<JSON>

=head1 AUTHOR

Alejandro Imass <ait@p2ee.org>
Alejandro Imass <aimass@corcaribe.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Alejandro Imass / Corcaribe Tecnología C.A. for the P2EE Project

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
