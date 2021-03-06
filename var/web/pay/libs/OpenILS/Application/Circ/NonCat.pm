package OpenILS::Application::Circ::NonCat;
use base 'OpenILS::Application';
use strict; use warnings;
use OpenSRF::EX qw(:try);
use Data::Dumper;
use OpenSRF::Utils::Logger qw(:logger);
use OpenILS::Application::AppUtils;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::Editor;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
$Data::Dumper::Indent = 0;

my $U = "OpenILS::Application::AppUtils";


# returns ( $newid, $evt ).  If $evt, then there was an error
sub create_non_cat_circ {
	my( $staffid, $patronid, $circ_lib, $noncat_type, $circ_time, $editor ) = @_;

	my( $id, $nct, $evt );
	$circ_time ||= 'now';
	my $circ = Fieldmapper::action::non_cataloged_circulation->new;

	$logger->activity("Creating non-cataloged circulation for ".
		"staff $staffid, patron $patronid, location $circ_lib, and non-cat type $noncat_type");

	$circ->patron($patronid);
	$circ->staff($staffid);
	$circ->circ_lib($circ_lib);
	$circ->item_type($noncat_type);
	$circ->circ_time($circ_time);

	if( $editor ) {
		$evt = $editor->event unless
			$circ = $editor->create_action_non_cataloged_circulation( $circ )

	} else {
		$id = $U->simplereq(
			'open-ils.storage',
			'open-ils.storage.direct.action.non_cataloged_circulation.create', $circ );
		$evt = $U->DB_UPDATE_FAILED($circ) unless $id;
		$circ->id($id);
	}

	return( $circ, $evt );
}


__PACKAGE__->register_method(
	method	=> "create_noncat_type",
	api_name	=> "open-ils.circ.non_cat_type.create",
	notes		=> q/
		Creates a new non cataloged item type
		@param authtoken The login session key
		@param name The name of the new type
		@param orgId The location where the type will live
		@return The type object on success and the corresponding
		event on failure
	/);

sub create_noncat_type {
	my( $self, $client, $authtoken, $name, $orgId, $interval, $inhouse ) = @_;

	my $e = new_editor(authtoken=>$authtoken, xact=>1);
	return $e->die_event unless $e->checkauth;
	return $e->die_event unless $e->allowed('CREATE_NON_CAT_TYPE', $orgId);

	# grab all of "my" non-cat types and see if one with 
	# the requested name already exists
	my $types = retrieve_noncat_types_all($self, $client, $orgId);
	for(@$types) {
		if( $_->name eq $name ) {
			$e->rollback;
			return OpenILS::Event->new('NON_CAT_TYPE_EXISTS', payload => $name);
		}
	}

	my $type = Fieldmapper::config::non_cataloged_type->new;
	$type->name($name);
	$type->owning_lib($orgId);
	$type->circ_duration($interval);
	$type->in_house( ($inhouse) ? 't' : 'f' );

	$e->create_config_non_cataloged_type($type) or return $e->die_event;
	$e->commit;
	return $type;
}



__PACKAGE__->register_method(
	method	=> "update_noncat_type",
	api_name	=> "open-ils.circ.non_cat_type.update",
	notes		=> q/
		Updates a non-cataloged type object
		@param authtoken The login session key
		@param type The updated type object
		@return The result of the DB update call unless a preceeding event occurs, 
			in which case the event will be returned
	/);

sub update_noncat_type {
	my( $self, $client, $authtoken, $type ) = @_;
	my $e = new_editor(xact=>1, authtoken=>$authtoken);
	return $e->die_event unless $e->checkauth;

	my $otype = $e->retrieve_config_non_cataloged_type($type->id) 
		or return $e->die_event;

	return $e->die_event unless 
		$e->allowed('UPDATE_NON_CAT_TYPE', $otype->owning_lib);

	$type->owning_lib($otype->owning_lib); # do not allow them to "move" the object

	$e->update_config_non_cataloged_type($type) or return $e->die_event;
	$e->commit;
	return 1;
}

__PACKAGE__->register_method(
	method	=> "retrieve_noncat_types_all",
	api_name	=> "open-ils.circ.non_cat_types.retrieve.all",
	notes		=> q/
		Retrieves the non-cat types at the requested location as well
		as those above and below the requested location in the org tree
		@param orgId The base location at which to retrieve the type objects
		@param depth Optional parameter to limit the depth of the tree
		@return An array of non cat type objects or an event if an error occurs
	/);

sub retrieve_noncat_types_all {
	my( $self, $client, $orgId, $depth ) = @_;
	my $meth = 'open-ils.storage.ranged.config.non_cataloged_type.retrieve.atomic';
	my $svc = 'open-ils.storage';
	return $U->simplereq($svc, $meth, $orgId, $depth) if defined($depth);
	return $U->simplereq($svc, $meth, $orgId);
}



__PACKAGE__->register_method(
	method		=> 'fetch_noncat',
	api_name		=> 'open-ils.circ.non_cataloged_circulation.retrieve',
	signature	=> q/
	/
);

sub fetch_noncat {
	my( $self, $conn, $auth, $circid ) = @_;
	my $e = OpenILS::Utils::Editor->new( authtoken => $auth );
	return $e->event unless $e->checkauth;
	my $c = $e->retrieve_action_non_cataloged_circulation($circid)
		or return $e->event;
	if( $c->patron ne $e->requestor->id ) {
		return $e->event unless $e->allowed('VIEW_CIRCULATIONS'); # XXX rely on editor perm
	}
	return $c;
}



__PACKAGE__->register_method(
	method => 'fetch_open_noncats',
    authoritative => 1,
	api_name	=> 'open-ils.circ.open_non_cataloged_circulation.user',
	signature => q/
		Returns an id-list of non-cataloged circulations that are considered
		open as of now.  a circ is open if circ time + circ duration 
		(based on type) is > than now.
		@param auth auth key
		@param userid user to retrieve non-cat circs for 
			defaults to the session user
	/
);

sub fetch_open_noncats {
	my( $self, $conn, $auth, $userid ) = @_;
	my $e = OpenILS::Utils::Editor->new( authtoken => $auth );
	return $e->event unless $e->checkauth;
	$userid ||= $e->requestor->id;
	if( $e->requestor->id ne $userid ) {
		return $e->event unless $e->allowed('VIEW_CIRCULATIONS'); # XXX rely on editor perm
	}
	return $e->request(
		'open-ils.storage.action.open_non_cataloged_circulation.user', $userid );
}


__PACKAGE__->register_method(
	method	=> 'delete_noncat',
	api_name	=> 'open-ils.circ.non_cataloged_type.delete',
);
sub delete_noncat {
	my( $self, $conn, $auth, $typeid ) = @_;
	my $e = new_editor(xact=>1, authtoken => $auth);
	return $e->die_event unless $e->checkauth;

	my $nc = $e->retrieve_config_non_cataloged_type($typeid)
		or return $e->die_event;

	$e->allowed('DELETE_NON_CAT_TYPE', $nc->owning_lib) # XXX rely on editor perm
		or return $e->die_event;

	#	XXX Add checks to see if this type is in use by a transaction

	$e->delete_config_non_cataloged_type($nc) or return $e->die_event;
	$e->commit;
	return 1;
}



1;
