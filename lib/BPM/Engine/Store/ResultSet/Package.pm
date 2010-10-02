
package BPM::Engine::Store::ResultSet::Package;
BEGIN {
    $BPM::Engine::Store::ResultSet::Package::VERSION   = '0.001';
    $BPM::Engine::Store::ResultSet::Package::AUTHORITY = 'cpan:SITETECH';    
    }

use Moose;
use Scalar::Util qw(blessed);
use File::Spec;
use File::ShareDir ();
use XML::LibXML;
use XML::LibXML::Simple ();
use BPM::XPDL;
use BPM::Engine::Exceptions qw/throw_model throw_install/;
extends 'DBIx::Class::ResultSet';

my %APPMAP = ();

sub active {
    my $self = shift;
    $self->search({ deleted => \'IS NULL'},
                  { order_by => \'priority ASC' });
}

sub deleted {
    my $self = shift;
    $self->search({ deleted => \'IS NOT NULL' },
                  { order_by => \'deleted DESC' });
}

sub create_from_xml {
    my ($self, $string) = @_;

    my $data = XML::LibXML::Simple::XMLin($string,
      ForceArray => [qw/
        ExtendedAttribute FormalParameter DataField ActualParameter
        Participant Application Responsible
        WorkflowProcess Activity Transition TransitionRestriction
        /],
      NormaliseSpace => 2,
      ValueAttr => [ 'GraphConformance' ],
      );    

    return $self->_create_from_hash($data);
    }

sub create_from_xpdl {
    my ($self, $args) = @_;

    unless(ref($args) eq 'HASH') {
        my $doc = $self->_xml_doc($args);
        $args = (BPM::XPDL->from($doc))[1];
        }
    
    return $self->_create_from_hash($args);
    }

sub _xml_doc {
    my ($self, $args) = @_;    
    
    my $parser = XML::LibXML->new;
    my $doc = undef;

    if(ref($args) eq 'SCALAR') {
        $doc = eval { $parser->parse_string($$args); };
        die "invalid XML: $@" if $@;                
        }
    elsif(!ref($args) && -f $args) {
        $doc = eval { $parser->parse_file($args); };
        die "invalid XML: $@" if $@;
        }
    else {
        die "file $args not found";
        }

    # get XPDL version from xml
    my @nodes = $doc->documentElement->getElementsByTagName('XPDLVersion');
    die "XPDLVersion not defined" unless $nodes[0];
    my $v = $nodes[0]->textContent or die "XPDL version not set";
    die "unsupported XPDL version $v" unless(grep { $v == $_ } qw/1.0 2.0 2.1 2.2/);
    $v =~ s/\./_/;
    
    # validate against schema since BPM::XPDL's validation is not very informative
    my $schema_file = _xpdl_spec($v);
    die "schema file not found" unless -f $schema_file;
    
    my $schema = XML::LibXML::Schema->new(location => $schema_file);
    eval { $schema->validate($doc); };
    die "non-conformant XML: \n$@" if $@;
    
    return $doc;
    }

sub _xpdl_spec {
    my $version = shift;
    
    my $fname = "XPDL_$version.xsd";
    my $file  = File::Spec->catfile('share', 'schemas', $fname);
    eval {
        $file = File::Spec->catfile(
            File::ShareDir::dist_file('BPM-Engine', 'schemas', $fname) );
        } unless(-e $file);
    
    throw_install(error => "Schema file '$fname' not found in shared dirs") unless(-e $file);
    
    return $file;
    }


sub _create_from_hash {
    my ($self, $args) = @_;

    %APPMAP = ();
    my $schema = $self->result_source->schema;
    
    my $create_txn = sub {
        #-- main element: Package
        my $entry = $self->create( {
            package_uid => $args->{Id},
            version     => '1.0',
            });
        $entry->package_name($args->{Name}) if($args->{Name});

        #-- element: PackageHeader (required)
        _import_packhead($entry, $args->{PackageHeader}) if $args->{PackageHeader};

        #-- element: RedefinableHeader
        _import_redefhead($entry, $args->{RedefinableHeader}) if $args->{RedefinableHeader};

        #-- element: ConformanceClass
        $entry->graph_conformance($args->{ConformanceClass}->{GraphConformance}) if ($args->{ConformanceClass});

        #-- element: Script
        #-- element: ExternalPackages
        #-- element: TypeDeclarations

        #-- element: Participants
        _import_participants($entry, $args->{Participants}->{Participant}) if $args->{Participants};

        #-- element: Applications
        _import_applications($entry, $args->{Applications}->{Application}) if $args->{Applications};

        #-- elements: Attributes (DataFields, ExtendedAttributes, FormalParameters, ActualParameters )
        _set_elements($entry, $args);

        #-- element: WorkflowProcesses
        _import_processes($entry, $args->{WorkflowProcesses}->{WorkflowProcess}) if $args->{WorkflowProcesses};

        #$entry->update();
        return $entry;
        };
    
    my $row;
    eval { $row = $schema->txn_do($create_txn); };
    if ($@) {
        die "Rollback failed!" if ($@ =~ /Rollback failed/);
        die("XML validation/integrity/completeness error: $@");
        }
    
    return $row;
    }

sub debug {
    #warn $_[0];
    }

sub _import_packhead {
    my ($entry, $args) = @_;

    my %columns = (
        description           => 'Description',
        specification_version => 'XPDLVersion',
        vendor                => 'Vendor',
        priority_uom          => 'PriorityUnit',
        cost_uom              => 'CostUnit',
        documentation_url     => 'Documentation',
        created               => 'Created',
        );

    $entry->specification(1);

    _set_values($entry, $args, \%columns);

    return;
    }

sub _import_redefhead {
    my ($entry, $args, $parent) = @_;

    my %columns = (
        version               => 'Version',
        author                => 'Author',
        codepage              => 'Codepage',
        country_geo           => 'Countrykey',
        publication_status    => 'PublicationStatus',
        );

    #-- element: Responsibles

    _set_values($entry, $args, \%columns,$parent);

    return;
    }

sub _import_participants {
    my ($entry, $args) = @_;

    debug('Importing participants');
    
    my $idx = 0;
    foreach my $part_proto(@{$args}) {
        my $participant = _import_participant($entry->participant_list, $part_proto, $idx);
        $participant->update();
        $idx++;
        }

    return;
    }

sub _import_participant {
    my ($plist, $args, $index) = @_;

    my $pid = delete $args->{Id};
    my $participant = $plist->add_to_participants({
        participant_uid   => $pid,
        participant_name  => delete $args->{Name} || $pid,
        description       => delete $args->{Description},
        participant_type  => delete $args->{ParticipantType}->{Type},
        });
    
    while (my($key, $value) = each %{$args->{ParticipantType}}) {
        $args->{$key} = $value;
        }
    delete $args->{ParticipantType};
    $participant->attributes($args) if(keys %{$args});
    
    return $participant;
    }

sub _import_applications {
    my ($entry, $args) = @_;
    
    debug('Importing applications');
    
    foreach my $app_proto(@{$args}) {
        my $app = _import_application($entry, $app_proto);
        $app->update();
        die("Double-def app") if($APPMAP{$app->application_uid});
        $APPMAP{$app->application_uid} = $app;
        }

    return;
    }

sub _import_application {
    my ($entry, $args) = @_;

    my $app = $entry->result_source->schema->resultset('Application')->create({
        application_uid   => $args->{Id},
        application_name  => $args->{Name} || $args->{Id},
        parent_node       => $entry->id,
        description       => $args->{Description},
        application_scope => ref($entry) =~ /Package/ ? 'Package' : 'Process',
        });

    _set_elements($app, $args);

    return $app;
    }

sub _import_processes {
    my ($entry, $args) = @_;
    
    debug('Importing processes');
    
    foreach my $process(@{$args}) {
        _import_process($entry, $process);
        }

    return;
    }

sub _import_process {
    my ($entry, $args) = @_;
    
    my $process = $entry->add_to_processes({
        process_uid  => $args->{Id},
        });
    $process->process_name($args->{Name}) if $args->{Name};

    #-- element: ProcessHeader
    my %columns = (
        description => 'Description',
        created     => 'Created',
        priority    => 'Priority',
        valid_from  => 'ValidFrom',
        valid_to    => 'ValidTo',
        );
    _set_values($process, $args->{ProcessHeader}, \%columns);

    #-- element: RedefinableHeader
    _import_redefhead($process, $args->{RedefinableHeader}, $entry);

    #-- elements: data fields
    _set_elements($process, $args);

    #-- element: Participants
    _import_participants($process, $args->{Participants}->{Participant}) if $args->{Participants};

    #-- element: Applications
    _import_applications($process, $args->{Applications}->{Application}) if $args->{Applications};

    #-- element: ActivitySets

    #-- element: Activities
    debug('Importing activities');
    my $i = 0;
    my $transition_map = {};
    my $deadline_map = {};
    if($args->{Activities} && $args->{Activities}->{Activity}) {
        foreach my $act_proto(@{ $args->{Activities}->{Activity} }) {
            my $activity = _import_activity($process, $act_proto, $transition_map, $deadline_map);
            $activity->update();
            ### XXX - needs2be Activity record without From/To entry in Transition table
            # $process->default_start_activity_id($activity->activity_id) unless $i;
            $i++;
            }
        }

    #-- element: Transitions
    debug('Importing transitions');    
    if($args->{Transitions} && $args->{Transitions}->{Transition}) {
        foreach my $trans_proto(@{ $args->{Transitions}->{Transition} }) {
            my $transition = _import_transition($process, $trans_proto, $transition_map, $deadline_map);
            $transition->update();
            }
        }

    die("Not all transitionrefs have matching transitions") if(scalar keys %{$transition_map});
    die("Not all deadlines have matching transition conditions") if(scalar keys %{$deadline_map});

    $process->update();

    return;
    }

sub _import_activity {
    my ($process, $args, $trans_map, $deadline_map) = @_;
    
    debug('Importing activity');

    #-- attributes
    my $activity = $process->add_to_activities({
        activity_uid     => $args->{Id},
        activity_name    => $args->{Name} || $args->{Id},
        activity_type    => $args->{Route} ? 'Route' : (
            $args->{BlockActivity} ? 'BlockActivity' : 'Implementation'
            ),
        });

    #-- elements: Description, Priority, Icon, Documentation
    my %columns = (
        description       => 'Description',
        priority          => 'Priority',
        documentation_url => 'Documentation',
        icon_url          => 'Icon',
        start_mode        => 'StartMode',
        finish_mode       => 'FinishMode',
        );
    _set_values($activity, $args, \%columns);

    _set_elements($activity, $args);

    #-- element: StartMode + FinishMode
    $activity->start_mode('Manual') if($args->{StartMode} && 
        ( ref($args->{StartMode}) ? $args->{StartMode}->{Manual} : ($args->{StartMode} eq 'Manual'))
        );
    $activity->finish_mode('Manual') if($args->{FinishMode} &&
        ( ref($args->{FinishMode}) ? $args->{FinishMode}->{Manual} : ($args->{FinishMode} eq 'Manual'))
        );
    
    #-- element: Deadline
    if($args->{Deadline}) {
        my @deadlines = @{ $args->{Deadline}->{Deadline} };
        foreach my $dead(@deadlines) {
            die("Illegal deadline") if ($deadline_map->{$dead->{'ExceptionName'}});
            $deadline_map->{$dead->{'ExceptionName'}} = {
                activity_id  => $activity->id,
                duration     => $dead->{'DeadlineDuration'},
                execution    => $dead->{'Execution'},
                };
            }
        }

    #-- element: TransitionRestrictions
    # split_type => 'SplitType',
    # join_type  => 'JoinType',
    if($args->{TransitionRestrictions}) {
        my @restrict = @{$args->{TransitionRestrictions}->{TransitionRestriction}};
        foreach my $r(@restrict) {
            my @rkeys = keys %{$r};
            die("Invalid TransitionRestriction") unless(scalar(@rkeys) == 1 || scalar(@rkeys) == 2);
            foreach my $rtype(@rkeys) {
                if($rtype eq 'Split') {
                    $activity->split_type($r->{$rtype}->{Type});
                    }
                elsif($rtype eq 'Join') {
                    $activity->join_type($r->{$rtype}->{Type});
                    }
                else {
                    die("Invalid TransitionRestriction");
                    }

                # from_split/to_join position starts at 1
                my $pos = 1;
                foreach my $trans(@{ $r->{$rtype}->{TransitionRefs}->{TransitionRef} }) {
                    $trans_map->{$trans->{Id}}->{$rtype} ||= [];
                    push(@{ $trans_map->{$trans->{Id}}->{$rtype} }, [$activity->id, $pos++]);
                    }
                }
            }
        }

    #-- element: Performer
    if($args->{Performers}) {
        my @performers = ref($args->{Performers}->{Performer}) ? 
                         @{$args->{Performers}->{Performer}} : 
                         $args->{Performers}->{Performer};
        _import_performers($process, $activity, @performers);
        }

    #-- element: Implementation Route BlockActivity Event
    if($activity->is_implementation_type) {
        #-- implementation_type: No Tool Task SubFlow Reference
        my $impl = $args->{Implementation} || { 'No' => undef };
        my @itypes = keys %{$impl};
        die("Invalid Activity implementation") unless(scalar(@itypes) == 1);
        $activity->implementation_type($itypes[0]);
        if($activity->is_impl_task) {
            my ($type, @tasks) = ();
            if($itypes[0] eq 'Tool') {
                @tasks = @{$impl->{Tool}};
                $type = 'Tool';
                foreach my $task(@tasks) {
                    _add_task($activity, $task, $type);
                    }
                }
            elsif($itypes[0] eq 'Task') {
                my @tkeys = keys %{$impl->{Task}};
                unless (scalar @tkeys < 2) {
                    die("Too many tasks (Task element takes no attributes");
                    }
                
                $type = $tkeys[0];
                if($type) {
                    my $task = $impl->{Task}->{$type};
                    $type =~ s/^Task//;
                    _prepare_task($type, $task);
                    _add_task($activity, $task, $type);
                    }
                }
            }
        elsif(!$activity->is_impl_no && !$activity->is_impl_subflow 
           && !$activity->is_impl_reference) {
            die("Invalid Activity implementation");
            }
        }
    elsif(!$activity->is_route_type && !$activity->is_block_type 
       && !$activity->is_event_type) {
        die("Invalid Activity implementation");
        }

    #-- element: Limit

    return $activity;
    }

sub _prepare_task {
    my ($type, $task) = @_;    

    debug('Preparing task');

    $task->{Script} = $task->{Script}->textContent 
        if(ref($task->{Script}) eq 'XML::LibXML::Element');

    # values for XML::LibXML::Element elements
    my $actual_params = delete $task->{ActualParameters}->{ActualParameter};
    if($actual_params) {
        $task->{ActualParameters}->{ActualParameter} = _mapxml($actual_params);
        }

    # normalize Actual and TestValue XML::LibXML::Element elements
    my $maps = $task->{DataMappings}->{DataMapping};
    if($maps) {
        foreach(@{$maps}) {
            $_->{TestValue} = _checkxml($_->{TestValue});
            $_->{Actual}    = _checkxml($_->{Actual});
            }
        }
    
    # normalize ActualParameter values
    my %msgtypes = ( 
        Message    => 'send|receive', 
        MessageIn  => 'user|service', 
        MessageOut => 'user|service'
        );
    foreach my $msgtype(keys %msgtypes) {
        if(my $del = delete $task->{$msgtype}->{ActualParameters}->{ActualParameter}) {
            my $re = $msgtypes{$msgtype};
            if($type =~ /$re/i) {
                $task->{$msgtype}->{ActualParameters}->{ActualParameter} = _mapxml($del);
                }
            else {
                die("XPDL trying to set nonsense $msgtype ActualParameters");
                }
            }
        
        if(my $del = delete $task->{$msgtype}->{DataMappings}->{DataMapping}) {        
            my $re = $msgtypes{$msgtype};
            if($type =~ /$re/i) {
                foreach ( @{ $task->{$msgtype}->{DataMappings}->{DataMapping} } ) {
                    $_->{TestValue} = _checkxml($_->{TestValue});
                    $_->{Actual}    = _checkxml($_->{Actual});
                    }
                }
            else {
                die("XPDL trying to set nonsense $msgtype ActualParameters");
                }
            }
        }
    }

sub _add_task {
    my ($activity, $task, $type) = @_;

    debug('Adding task');

    my $task_tool = $activity->add_to_tasks({
        task_uid    => $task->{Id},
        task_name   => delete $task->{Name} || $activity->activity_name,
        description => delete $task->{Description} || $activity->description,
        task_type   => $type,
        }) or die("Invalid Task");
    if($type eq 'Tool' || $type eq 'Application') {
        my $app = $APPMAP{ $task->{Id} } or die("No application for task $task->{Id}");
        $task_tool->application_id($app->id);
        }

    _set_elements($task_tool, $task);
    delete $task->{Id};
    
    debug('Setting taskdata');
    delete $task->{'WebServiceFaultCatch'};
    $task_tool->task_data($task) if(keys %{$task});
    $task_tool->update();
    }

sub _import_performers {
    my ($process, $activity, @performers) = @_;

    debug('Importing performers');

    my $i = 0;
    foreach my $performer(@performers) {
        die("Invalid Performer (Missing element data)") unless $performer;
        my $participant =
            $process->participant_list->participants({
                participant_uid => $performer
                })->first
            || $process->package->participant_list->participants({
                participant_uid => $performer
                })->first
            or die("Illegal Performer $performer (Participant unknown)");
        $activity->add_to_performers({
            participant_id => $participant->id,
            performer_index => $i++,
            }) or die("Performer $performer not created");
        }
    }

sub _import_transition {
    my ($process, $args, $trans_map, $deadline_map) = @_;
    
    debug('Importing transition');

    my $act_out = join( '_', split( /\s+/, $args->{From} ) );
    my $act_in  = join( '_', split( /\s+/, $args->{To} ) );
    my $from    = $process->activities->search({ activity_uid => $act_out })->next or die("Unknown activity $args->{From}");
    my $to      = $process->activities->search({ activity_uid => $act_in   })->next or die("Unknown activity $args->{To}");

    my $transition = $process->add_to_transitions({
        transition_uid   => $args->{Id},
        transition_name  => $args->{Name},
        from_activity_id => $from->id,
        to_activity_id   => $to->id,
        });

    if($args->{Description}) {
        $transition->description($args->{Description});
        }

    if($args->{Condition}) {
        my $condition = $args->{Condition};
        if(ref($condition) eq 'XML::LibXML::Element') {
            if(my $ctype = $condition->getAttributeNode('Type')) {
                $transition->condition_type($ctype->nodeValue);
                }
            else {
                # this shouldn't be needed, as it is the default value in schema def?
                $transition->condition_type('NONE');
                }
            
            my @exprs = $condition->getChildrenByTagName('Expression');
            my $expr = $exprs[0] || $condition;            
            if(my $line = _trim($expr->textContent)) {
                $transition->condition_expr($line);
                }
            }
        else {
            $transition->condition_type($args->{Condition}->{Type} || 'NONE');
            $transition->condition_expr($condition->{content});
            }
        
        my $ctype = $transition->condition_type || die("No condition type");
        if($ctype eq 'EXCEPTION') {
            if(my $dead = delete $deadline_map->{ $transition->condition_expr } ) {
                $transition->create_related(deadline => $dead)
                    or die("Could not create deadline");
                }
            }

        }

    # transition references
    if($args->{Id} && $trans_map->{ $args->{Id} }) {
        my $tref = delete $trans_map->{$args->{Id}};
        foreach my $type(grep { $tref->{$_} } qw/Split Join/) {
            my $rel = $type eq 'Split' ? 'from_split' : 'to_join';
            foreach my $activity_set(@{ $tref->{$type} }) {
                $transition->create_related($rel, {
                    activity_id   => $activity_set->[0],
                    position      => $activity_set->[1],
                    split_or_join => uc($type),
                    });
                }
            }
        }

    return $transition;
    }

sub _set_values {
    my ($entry,$args,$cols,$parent) = @_;

    debug('Setting values');

    my %columns = %{$cols};
    foreach my $method(keys %columns) {
        my $value = $args->{ $columns{$method} };
        next if(ref($value));
        $value ||= $parent->$method if $parent;
        $entry->$method($value) if $value;
        }

    return;
    }

sub _trim {
	my $content = shift;
	return unless defined $content;
    $content =~ s/(^\s*|\s*$)//g;
    return $content;
    }

#-- elements: DataFields, ExtendedAttributes, FormalParameters, ActualParameters
sub _set_elements {
    my ($entry, $args) = @_;

    debug('Importing elements');

    my $a = { actual_params => [ 'ActualParameters', 'ActualParameter' ] };
    my $f = { formal_params => [ 'FormalParameters', 'FormalParameter' ] };
    my $d = { data_fields   => [ 'DataFields', 'DataField' ] };
    my $s = { assignments   => [ 'Assignments', 'Assignment' ] };
    my $m = { data_maps     => [ 'DataMappings', 'DataMapping' ] };
    my $e = { extended_attr => [ 'ExtendedAttributes', 'ExtendedAttribute' ] };
    my %types = (
        Package      => [$e,$d],
        Application  => [$f,$e],
        Process      => [$f,$e,$d,$s],
        Activity     => [$e,$d,$s],
        ActivityTask => [$a,$m,$e],
        Transition   => [$s],
        #Message(In|Out)      => [],
        );
    my @pack = grep { ref($entry) =~ /^BPM::Engine::Store::Result::($_)$/ } keys %types;
    die("Invalid regexp $entry ") unless scalar @pack == 1;
    
    foreach my $type(@{ $types{$pack[0]} }) {
        my $field = (keys %{$type})[0];
        my ($multi, $single) = @{ $type->{$field} };
        if($args->{$multi} && $args->{$multi}->{$single}) {
            my $json = delete $args->{$multi}->{$single};
            delete $args->{$multi};
            next unless $json->[0];
            # HACKS XML::LibXML::Element
            if($multi eq 'ExtendedAttributes' && ref($json->[0]) eq 'XML::LibXML::Element') {
                $json = [map { { Name => $_->getAttribute('Name') , Value => $_->getAttribute('Value') } } @$json];
                }
            elsif($multi eq 'DataFields') {
                # DataFields might still contain some XML::LibXML::Element in XPDL 2.1 definitions
                foreach my $att(@$json) {
                    next unless(ref($att) eq 'HASH');
                    if($att->{InitialValue} && ref($att->{InitialValue}) eq 'XML::LibXML::Element') {
                        $att->{InitialValue} = _checkxml($att->{InitialValue});
                        }
                    }
                }
            elsif($pack[0] eq 'ActivityTask' && $multi eq 'ActualParameters') {
                $json = _mapxml($json);
                }
            elsif($pack[0] eq 'ActivityTask' && $multi eq 'DataMappings') {
                foreach(@{$json}) {
                    _hashxml($_);
                    }
                }
            elsif($multi eq 'Assignments') {
                foreach(@{$json}) {
                    _hashxml($_);
                    }
                }
            eval {
                $entry->$field($json);
                };
            if($@) {
                warn "Error setting $field as JSON: $@";
                }
            }
        }

    }

sub _hashxml {
    my $hash = shift;
    foreach my $key(keys %{$hash}) {
        $hash->{$key} = _checkxml($hash->{$key});
        delete $hash->{$key} unless $hash->{$key};
        }
    }

sub _mapxml {
    my $val = shift;
    return [ grep { $_ } map { _checkxml($_) } @{$val} ];
    }

sub _checkxml {
    my $val = shift;
    return unless $val;
    #return blessed $val ? $val->textContent : $val;
    return $val->textContent if blessed($val);
    return $val->{content}   if ref($val);
    return $val;
    }

__PACKAGE__->meta->make_immutable( inline_constructor => 0 );
no Moose;

1;
__END__