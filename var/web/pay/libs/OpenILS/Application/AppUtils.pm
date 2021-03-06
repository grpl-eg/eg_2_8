package OpenILS::Application::AppUtils;
# vim:noet:ts=4
use strict; use warnings;
use OpenILS::Application;
use base qw/OpenILS::Application/;
use OpenSRF::Utils::Cache;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Utils::ModsParser;
use OpenSRF::EX qw(:try);
use OpenILS::Event;
use Data::Dumper;
use OpenILS::Utils::CStoreEditor;
use OpenILS::Const qw/:const/;
use Unicode::Normalize;
use OpenSRF::Utils::SettingsClient;

# ---------------------------------------------------------------------------
# Pile of utilty methods used accross applications.
# ---------------------------------------------------------------------------
my $cache_client = "OpenSRF::Utils::Cache";


# ---------------------------------------------------------------------------
# on sucess, returns the created session, on failure throws ERROR exception
# ---------------------------------------------------------------------------
sub start_db_session {

	my $self = shift;
	my $session = OpenSRF::AppSession->connect( "open-ils.storage" );
	my $trans_req = $session->request( "open-ils.storage.transaction.begin" );

	my $trans_resp = $trans_req->recv();
	if(ref($trans_resp) and UNIVERSAL::isa($trans_resp,"Error")) { throw $trans_resp; }
	if( ! $trans_resp->content() ) {
		throw OpenSRF::ERROR 
			("Unable to Begin Transaction with database" );
	}
	$trans_req->finish();

	$logger->debug("Setting global storage session to ".
		"session: " . $session->session_id . " : " . $session->app );

	return $session;
}

my $PERM_QUERY = {
    select => {
        au => [ {
            transform => 'permission.usr_has_perm',
            alias => 'has_perm',
            column => 'id',
            params => []
        } ]
    },
    from => 'au',
    where => {},
};


# returns undef if user has all of the perms provided
# returns the first failed perm on failure
sub check_user_perms {
	my($self, $user_id, $org_id, @perm_types ) = @_;
	$logger->debug("Checking perms with user : $user_id , org: $org_id, @perm_types");

	for my $type (@perm_types) {
	    $PERM_QUERY->{select}->{au}->[0]->{params} = [$type, $org_id];
		$PERM_QUERY->{where}->{id} = $user_id;
		return $type unless $self->is_true(OpenILS::Utils::CStoreEditor->new->json_query($PERM_QUERY)->[0]->{has_perm});
	}
	return undef;
}

# checks the list of user perms.  The first one that fails returns a new
sub check_perms {
	my( $self, $user_id, $org_id, @perm_types ) = @_;
	my $t = $self->check_user_perms( $user_id, $org_id, @perm_types );
	return OpenILS::Event->new('PERM_FAILURE', ilsperm => $t, ilspermloc => $org_id ) if $t;
	return undef;
}



# ---------------------------------------------------------------------------
# commits and destroys the session
# ---------------------------------------------------------------------------
sub commit_db_session {
	my( $self, $session ) = @_;

	my $req = $session->request( "open-ils.storage.transaction.commit" );
	my $resp = $req->recv();

	if(!$resp) {
		throw OpenSRF::EX::ERROR ("Unable to commit db session");
	}

	if(UNIVERSAL::isa($resp,"Error")) { 
		throw $resp ($resp->stringify); 
	}

	if(!$resp->content) {
		throw OpenSRF::EX::ERROR ("Unable to commit db session");
	}

	$session->finish();
	$session->disconnect();
	$session->kill_me();
}

sub rollback_db_session {
	my( $self, $session ) = @_;

	my $req = $session->request("open-ils.storage.transaction.rollback");
	my $resp = $req->recv();
	if(UNIVERSAL::isa($resp,"Error")) { throw $resp;  }

	$session->finish();
	$session->disconnect();
	$session->kill_me();
}


# returns undef it the event is not an ILS event
# returns the event code otherwise
sub event_code {
	my( $self, $evt ) = @_;
	return $evt->{ilsevent} if( ref($evt) eq 'HASH' and defined($evt->{ilsevent})) ;
	return undef;
}

# ---------------------------------------------------------------------------
# Checks to see if a user is logged in.  Returns the user record on success,
# throws an exception on error.
# ---------------------------------------------------------------------------
sub check_user_session {

	my( $self, $user_session ) = @_;

	my $content = $self->simplereq( 
		'open-ils.auth', 
		'open-ils.auth.session.retrieve', $user_session );

	if(! $content or $self->event_code($content)) {
		throw OpenSRF::EX::ERROR 
			("Session [$user_session] cannot be authenticated" );
	}

	$logger->debug("Fetch user session $user_session found user " . $content->id );

	return $content;
}

# generic simple request returning a scalar value
sub simplereq {
	my($self, $service, $method, @params) = @_;
	return $self->simple_scalar_request($service, $method, @params);
}


sub simple_scalar_request {
	my($self, $service, $method, @params) = @_;

	my $session = OpenSRF::AppSession->create( $service );

	my $request = $session->request( $method, @params );

	my $val;
	my $err;
	try  {

		$val = $request->gather(1);	

	} catch Error with {
		$err = shift;
	};

	if( $err ) {
		warn "received error : service=$service : method=$method : params=".Dumper(\@params) . "\n $err";
		throw $err ("Call to $service for method $method \n failed with exception: $err : " );
	}

	return $val;
}





my $tree						= undef;
my $orglist					= undef;
my $org_typelist			= undef;
my $org_typelist_hash	= {};

sub __get_org_tree {
	
	# can we throw this version away??

	my $self = shift;
	if($tree) { return $tree; }

	# see if it's in the cache
	$tree = $cache_client->new()->get_cache('_orgtree');
	if($tree) { return $tree; }

	if(!$orglist) {
		warn "Retrieving Org Tree\n";
		$orglist = $self->simple_scalar_request( 
			"open-ils.cstore", 
			"open-ils.cstore.direct.actor.org_unit.search.atomic",
			{ id => { '!=' => undef } }
		);
	}

	if( ! $org_typelist ) {
		warn "Retrieving org types\n";
		$org_typelist = $self->simple_scalar_request( 
			"open-ils.cstore", 
			"open-ils.cstore.direct.actor.org_unit_type.search.atomic",
			{ id => { '!=' => undef } }
		);
		$self->build_org_type($org_typelist);
	}

	$tree = $self->build_org_tree($orglist,1);
	$cache_client->new()->put_cache('_orgtree', $tree);
	return $tree;

}

my $slimtree = undef;
sub get_slim_org_tree {

	my $self = shift;
	if($slimtree) { return $slimtree; }

	# see if it's in the cache
	$slimtree = $cache_client->new()->get_cache('slimorgtree');
	if($slimtree) { return $slimtree; }

	if(!$orglist) {
		warn "Retrieving Org Tree\n";
		$orglist = $self->simple_scalar_request( 
			"open-ils.cstore", 
			"open-ils.cstore.direct.actor.org_unit.search.atomic",
			{ id => { '!=' => undef } }
		);
	}

	$slimtree = $self->build_org_tree($orglist);
	$cache_client->new->put_cache('slimorgtree', $slimtree);
	return $slimtree;

}


sub build_org_type { 
	my($self, $org_typelist)  = @_;
	for my $type (@$org_typelist) {
		$org_typelist_hash->{$type->id()} = $type;
	}
}



sub build_org_tree {

	my( $self, $orglist, $add_types ) = @_;

	return $orglist unless ref $orglist; 
    return $$orglist[0] if @$orglist == 1;

	my @list = sort { 
		$a->ou_type <=> $b->ou_type ||
		$a->name cmp $b->name } @$orglist;

	for my $org (@list) {

		next unless ($org);

		if(!ref($org->ou_type()) and $add_types) {
			$org->ou_type( $org_typelist_hash->{$org->ou_type()});
		}

		next unless (defined($org->parent_ou));

		my ($parent) = grep { $_->id == $org->parent_ou } @list;
		next unless $parent;
		$parent->children([]) unless defined($parent->children); 
		push( @{$parent->children}, $org );
	}

	return $list[0];
}

sub fetch_closed_date {
	my( $self, $cd ) = @_;
	my $evt;
	
	$logger->debug("Fetching closed_date $cd from cstore");

	my $cd_obj = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.actor.org_unit.closed_date.retrieve', $cd );

	if(!$cd_obj) {
		$logger->info("closed_date $cd not found in the db");
		$evt = OpenILS::Event->new('ACTOR_USER_NOT_FOUND');
	}

	return ($cd_obj, $evt);
}

sub fetch_user {
	my( $self, $userid ) = @_;
	my( $user, $evt );
	
	$logger->debug("Fetching user $userid from cstore");

	$user = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.actor.user.retrieve', $userid );

	if(!$user) {
		$logger->info("User $userid not found in the db");
		$evt = OpenILS::Event->new('ACTOR_USER_NOT_FOUND');
	}

	return ($user, $evt);
}

sub checkses {
	my( $self, $session ) = @_;
	my $user; my $evt; my $e; 

	$logger->debug("Checking user session $session");

	try {
		$user = $self->check_user_session($session);
	} catch Error with { $e = 1; };

	$logger->debug("Done checking user session $session " . (($e) ? "error = $e" : "") );

	if( $e or !$user ) { $evt = OpenILS::Event->new('NO_SESSION'); }
	return ( $user, $evt );
}


# verifiese the session and checks the permissions agains the
# session user and the user's home_ou as the org id
sub checksesperm {
	my( $self, $session, @perms ) = @_;
	my $user; my $evt; my $e; 
	$logger->debug("Checking user session $session and perms @perms");
	($user, $evt) = $self->checkses($session);
	return (undef, $evt) if $evt;
	$evt = $self->check_perms($user->id, $user->home_ou, @perms);
	return ($user, $evt);
}


sub checkrequestor {
	my( $self, $staffobj, $userid, @perms ) = @_;
	my $user; my $evt;
	$userid = $staffobj->id unless defined $userid;

	$logger->debug("checkrequestor(): requestor => " . $staffobj->id . ", target => $userid");

	if( $userid ne $staffobj->id ) {
		($user, $evt) = $self->fetch_user($userid);
		return (undef, $evt) if $evt;
		$evt = $self->check_perms( $staffobj->id, $user->home_ou, @perms );

	} else {
		$user = $staffobj;
	}

	return ($user, $evt);
}

sub checkses_requestor {
	my( $self, $authtoken, $targetid, @perms ) = @_;
	my( $requestor, $target, $evt );

	($requestor, $evt) = $self->checkses($authtoken);
	return (undef, undef, $evt) if $evt;

	($target, $evt) = $self->checkrequestor( $requestor, $targetid, @perms );
	return( $requestor, $target, $evt);
}

sub fetch_copy {
	my( $self, $copyid ) = @_;
	my( $copy, $evt );

	$logger->debug("Fetching copy $copyid from cstore");

	$copy = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.asset.copy.retrieve', $copyid );

	if(!$copy) { $evt = OpenILS::Event->new('ASSET_COPY_NOT_FOUND'); }

	return( $copy, $evt );
}


# retrieves a circ object by id
sub fetch_circulation {
	my( $self, $circid ) = @_;
	my $circ; my $evt;
	
	$logger->debug("Fetching circ $circid from cstore");

	$circ = $self->simplereq(
		'open-ils.cstore',
		"open-ils.cstore.direct.action.circulation.retrieve", $circid );

	if(!$circ) {
		$evt = OpenILS::Event->new('ACTION_CIRCULATION_NOT_FOUND', circid => $circid );
	}

	return ( $circ, $evt );
}

sub fetch_record_by_copy {
	my( $self, $copyid ) = @_;
	my( $record, $evt );

	$logger->debug("Fetching record by copy $copyid from cstore");

	$record = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.asset.copy.retrieve', $copyid,
		{ flesh => 3,
		  flesh_fields => {	bre => [ 'fixed_fields' ],
					acn => [ 'record' ],
					acp => [ 'call_number' ],
				  }
		}
	);

	if(!$record) {
		$evt = OpenILS::Event->new('BIBLIO_RECORD_ENTRY_NOT_FOUND');
	} else {
		$record = $record->call_number->record;
	}

	return ($record, $evt);
}

# turns a record object into an mvr (mods) object
sub record_to_mvr {
	my( $self, $record ) = @_;
	return undef unless $record and $record->marc;
	my $u = OpenILS::Utils::ModsParser->new();
	$u->start_mods_batch( $record->marc );
	my $mods = $u->finish_mods_batch();
	$mods->doc_id($record->id);
   $mods->tcn($record->tcn_value);
	return $mods;
}

sub fetch_hold {
	my( $self, $holdid ) = @_;
	my( $hold, $evt );

	$logger->debug("Fetching hold $holdid from cstore");

	$hold = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.action.hold_request.retrieve', $holdid);

	$evt = OpenILS::Event->new('ACTION_HOLD_REQUEST_NOT_FOUND', holdid => $holdid) unless $hold;

	return ($hold, $evt);
}


sub fetch_hold_transit_by_hold {
	my( $self, $holdid ) = @_;
	my( $transit, $evt );

	$logger->debug("Fetching transit by hold $holdid from cstore");

	$transit = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.action.hold_transit_copy.search', { hold => $holdid } );

	$evt = OpenILS::Event->new('ACTION_HOLD_TRANSIT_COPY_NOT_FOUND', holdid => $holdid) unless $transit;

	return ($transit, $evt );
}

# fetches the captured, but not fulfilled hold attached to a given copy
sub fetch_open_hold_by_copy {
	my( $self, $copyid ) = @_;
	$logger->debug("Searching for active hold for copy $copyid");
	my( $hold, $evt );

	$hold = $self->cstorereq(
		'open-ils.cstore.direct.action.hold_request.search',
		{ 
			current_copy		=> $copyid , 
			capture_time		=> { "!=" => undef }, 
			fulfillment_time	=> undef,
			cancel_time			=> undef,
		} );

	$evt = OpenILS::Event->new('ACTION_HOLD_REQUEST_NOT_FOUND', copyid => $copyid) unless $hold;
	return ($hold, $evt);
}

sub fetch_hold_transit {
	my( $self, $transid ) = @_;
	my( $htransit, $evt );
	$logger->debug("Fetching hold transit with hold id $transid");
	$htransit = $self->cstorereq(
		'open-ils.cstore.direct.action.hold_transit_copy.retrieve', $transid );
	$evt = OpenILS::Event->new('ACTION_HOLD_TRANSIT_COPY_NOT_FOUND', id => $transid) unless $htransit;
	return ($htransit, $evt);
}

sub fetch_copy_by_barcode {
	my( $self, $barcode ) = @_;
	my( $copy, $evt );

	$logger->debug("Fetching copy by barcode $barcode from cstore");

	$copy = $self->simplereq( 'open-ils.cstore',
		'open-ils.cstore.direct.asset.copy.search', { barcode => $barcode, deleted => 'f'} );
		#'open-ils.storage.direct.asset.copy.search.barcode', $barcode );

	$evt = OpenILS::Event->new('ASSET_COPY_NOT_FOUND', barcode => $barcode) unless $copy;

	return ($copy, $evt);
}

sub fetch_open_billable_transaction {
	my( $self, $transid ) = @_;
	my( $transaction, $evt );

	$logger->debug("Fetching open billable transaction $transid from cstore");

	$transaction = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.money.open_billable_transaction_summary.retrieve',  $transid);

	$evt = OpenILS::Event->new(
		'MONEY_OPEN_BILLABLE_TRANSACTION_SUMMARY_NOT_FOUND', transid => $transid ) unless $transaction;

	return ($transaction, $evt);
}



my %buckets;
$buckets{'biblio'} = 'biblio_record_entry_bucket';
$buckets{'callnumber'} = 'call_number_bucket';
$buckets{'copy'} = 'copy_bucket';
$buckets{'user'} = 'user_bucket';

sub fetch_container {
	my( $self, $id, $type ) = @_;
	my( $bucket, $evt );

	$logger->debug("Fetching container $id with type $type");

	my $e = 'CONTAINER_CALL_NUMBER_BUCKET_NOT_FOUND';
	$e = 'CONTAINER_BIBLIO_RECORD_ENTRY_BUCKET_NOT_FOUND' if $type eq 'biblio';
	$e = 'CONTAINER_USER_BUCKET_NOT_FOUND' if $type eq 'user';
	$e = 'CONTAINER_COPY_BUCKET_NOT_FOUND' if $type eq 'copy';

	my $meth = $buckets{$type};
	$bucket = $self->simplereq(
		'open-ils.cstore',
		"open-ils.cstore.direct.container.$meth.retrieve", $id );

	$evt = OpenILS::Event->new(
		$e, container => $id, container_type => $type ) unless $bucket;

	return ($bucket, $evt);
}


sub fetch_container_e {
	my( $self, $editor, $id, $type ) = @_;

	my( $bucket, $evt );
	$bucket = $editor->retrieve_container_copy_bucket($id) if $type eq 'copy';
	$bucket = $editor->retrieve_container_call_number_bucket($id) if $type eq 'callnumber';
	$bucket = $editor->retrieve_container_biblio_record_entry_bucket($id) if $type eq 'biblio';
	$bucket = $editor->retrieve_container_user_bucket($id) if $type eq 'user';

	$evt = $editor->event unless $bucket;
	return ($bucket, $evt);
}

sub fetch_container_item_e {
	my( $self, $editor, $id, $type ) = @_;

	my( $bucket, $evt );
	$bucket = $editor->retrieve_container_copy_bucket_item($id) if $type eq 'copy';
	$bucket = $editor->retrieve_container_call_number_bucket_item($id) if $type eq 'callnumber';
	$bucket = $editor->retrieve_container_biblio_record_entry_bucket_item($id) if $type eq 'biblio';
	$bucket = $editor->retrieve_container_user_bucket_item($id) if $type eq 'user';

	$evt = $editor->event unless $bucket;
	return ($bucket, $evt);
}





sub fetch_container_item {
	my( $self, $id, $type ) = @_;
	my( $bucket, $evt );

	$logger->debug("Fetching container item $id with type $type");

	my $meth = $buckets{$type} . "_item";

	$bucket = $self->simplereq(
		'open-ils.cstore',
		"open-ils.cstore.direct.container.$meth.retrieve", $id );


	my $e = 'CONTAINER_CALL_NUMBER_BUCKET_ITEM_NOT_FOUND';
	$e = 'CONTAINER_BIBLIO_RECORD_ENTRY_BUCKET_ITEM_NOT_FOUND' if $type eq 'biblio';
	$e = 'CONTAINER_USER_BUCKET_ITEM_NOT_FOUND' if $type eq 'user';
	$e = 'CONTAINER_COPY_BUCKET_ITEM_NOT_FOUND' if $type eq 'copy';

	$evt = OpenILS::Event->new(
		$e, itemid => $id, container_type => $type ) unless $bucket;

	return ($bucket, $evt);
}


sub fetch_patron_standings {
	my $self = shift;
	$logger->debug("Fetching patron standings");	
	return $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.config.standing.search.atomic', { id => { '!=' => undef } });
}


sub fetch_permission_group_tree {
	my $self = shift;
	$logger->debug("Fetching patron profiles");	
	return $self->simplereq(
		'open-ils.actor', 
		'open-ils.actor.groups.tree.retrieve' );
}


sub fetch_patron_circ_summary {
	my( $self, $userid ) = @_;
	$logger->debug("Fetching patron summary for $userid");
	my $summary = $self->simplereq(
		'open-ils.storage', 
		"open-ils.storage.action.circulation.patron_summary", $userid );

	if( $summary ) {
		$summary->[0] ||= 0;
		$summary->[1] ||= 0.0;
		return $summary;
	}
	return undef;
}


sub fetch_copy_statuses {
	my( $self ) = @_;
	$logger->debug("Fetching copy statuses");
	return $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.config.copy_status.search.atomic', { id => { '!=' => undef } });
}

sub fetch_copy_location {
	my( $self, $id ) = @_;
	my $evt;
	my $cl = $self->cstorereq(
		'open-ils.cstore.direct.asset.copy_location.retrieve', $id );
	$evt = OpenILS::Event->new('ASSET_COPY_LOCATION_NOT_FOUND') unless $cl;
	return ($cl, $evt);
}

sub fetch_copy_locations {
	my $self = shift; 
	return $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.asset.copy_location.search.atomic', { id => { '!=' => undef } });
}

sub fetch_copy_location_by_name {
	my( $self, $name, $org ) = @_;
	my $evt;
	my $cl = $self->cstorereq(
		'open-ils.cstore.direct.asset.copy_location.search',
			{ name => $name, owning_lib => $org } );
	$evt = OpenILS::Event->new('ASSET_COPY_LOCATION_NOT_FOUND') unless $cl;
	return ($cl, $evt);
}

sub fetch_callnumber {
	my( $self, $id ) = @_;
	my $evt = undef;

	my $e = OpenILS::Event->new( 'ASSET_CALL_NUMBER_NOT_FOUND', id => $id );
	return( undef, $e ) unless $id;

	$logger->debug("Fetching callnumber $id");

	my $cn = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.asset.call_number.retrieve', $id );
	$evt = $e  unless $cn;

	return ( $cn, $evt );
}

my %ORG_CACHE; # - these rarely change, so cache them..
sub fetch_org_unit {
	my( $self, $id ) = @_;
	return undef unless $id;
	return $id if( ref($id) eq 'Fieldmapper::actor::org_unit' );
	return $ORG_CACHE{$id} if $ORG_CACHE{$id};
	$logger->debug("Fetching org unit $id");
	my $evt = undef;

	my $org = $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.actor.org_unit.retrieve', $id );
	$evt = OpenILS::Event->new( 'ACTOR_ORG_UNIT_NOT_FOUND', id => $id ) unless $org;
	$ORG_CACHE{$id}  = $org;

	return ($org, $evt);
}

sub fetch_stat_cat {
	my( $self, $type, $id ) = @_;
	my( $cat, $evt );
	$logger->debug("Fetching $type stat cat: $id");
	$cat = $self->simplereq(
		'open-ils.cstore', 
		"open-ils.cstore.direct.$type.stat_cat.retrieve", $id );

	my $e = 'ASSET_STAT_CAT_NOT_FOUND';
	$e = 'ACTOR_STAT_CAT_NOT_FOUND' if $type eq 'actor';

	$evt = OpenILS::Event->new( $e, id => $id ) unless $cat;
	return ( $cat, $evt );
}

sub fetch_stat_cat_entry {
	my( $self, $type, $id ) = @_;
	my( $entry, $evt );
	$logger->debug("Fetching $type stat cat entry: $id");
	$entry = $self->simplereq(
		'open-ils.cstore', 
		"open-ils.cstore.direct.$type.stat_cat_entry.retrieve", $id );

	my $e = 'ASSET_STAT_CAT_ENTRY_NOT_FOUND';
	$e = 'ACTOR_STAT_CAT_ENTRY_NOT_FOUND' if $type eq 'actor';

	$evt = OpenILS::Event->new( $e, id => $id ) unless $entry;
	return ( $entry, $evt );
}


sub find_org {
	my( $self, $org_tree, $orgid )  = @_;
    return undef unless $org_tree and defined $orgid;
	return $org_tree if ( $org_tree->id eq $orgid );
	return undef unless ref($org_tree->children);
	for my $c (@{$org_tree->children}) {
		my $o = $self->find_org($c, $orgid);
		return $o if $o;
	}
	return undef;
}

sub fetch_non_cat_type_by_name_and_org {
	my( $self, $name, $orgId ) = @_;
	$logger->debug("Fetching non cat type $name at org $orgId");
	my $types = $self->simplereq(
		'open-ils.cstore',
		'open-ils.cstore.direct.config.non_cataloged_type.search.atomic',
		{ name => $name, owning_lib => $orgId } );
	return ($types->[0], undef) if($types and @$types);
	return (undef, OpenILS::Event->new('CONFIG_NON_CATALOGED_TYPE_NOT_FOUND') );
}

sub fetch_non_cat_type {
	my( $self, $id ) = @_;
	$logger->debug("Fetching non cat type $id");
	my( $type, $evt );
	$type = $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.config.non_cataloged_type.retrieve', $id );
	$evt = OpenILS::Event->new('CONFIG_NON_CATALOGED_TYPE_NOT_FOUND') unless $type;
	return ($type, $evt);
}

sub DB_UPDATE_FAILED { 
	my( $self, $payload ) = @_;
	return OpenILS::Event->new('DATABASE_UPDATE_FAILED', 
		payload => ($payload) ? $payload : undef ); 
}

sub fetch_circ_duration_by_name {
	my( $self, $name ) = @_;
	my( $dur, $evt );
	$dur = $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.config.rules.circ_duration.search.atomic', { name => $name } );
	$dur = $dur->[0];
	$evt = OpenILS::Event->new('CONFIG_RULES_CIRC_DURATION_NOT_FOUND') unless $dur;
	return ($dur, $evt);
}

sub fetch_recurring_fine_by_name {
	my( $self, $name ) = @_;
	my( $obj, $evt );
	$obj = $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.config.rules.recuring_fine.search.atomic', { name => $name } );
	$obj = $obj->[0];
	$evt = OpenILS::Event->new('CONFIG_RULES_RECURING_FINE_NOT_FOUND') unless $obj;
	return ($obj, $evt);
}

sub fetch_max_fine_by_name {
	my( $self, $name ) = @_;
	my( $obj, $evt );
	$obj = $self->simplereq(
		'open-ils.cstore', 
		'open-ils.cstore.direct.config.rules.max_fine.search.atomic', { name => $name } );
	$obj = $obj->[0];
	$evt = OpenILS::Event->new('CONFIG_RULES_MAX_FINE_NOT_FOUND') unless $obj;
	return ($obj, $evt);
}

sub storagereq {
	my( $self, $method, @params ) = @_;
	return $self->simplereq(
		'open-ils.storage', $method, @params );
}

sub cstorereq {
	my( $self, $method, @params ) = @_;
	return $self->simplereq(
		'open-ils.cstore', $method, @params );
}

sub event_equals {
	my( $self, $e, $name ) =  @_;
	if( $e and ref($e) eq 'HASH' and 
		defined($e->{textcode}) and $e->{textcode} eq $name ) {
		return 1 ;
	}
	return 0;
}

sub logmark {
	my( undef, $f, $l ) = caller(0);
	my( undef, undef, undef, $s ) = caller(1);
	$s =~ s/.*:://g;
	$f =~ s/.*\///g;
	$logger->debug("LOGMARK: $f:$l:$s");
}

# takes a copy id 
sub fetch_open_circulation {
	my( $self, $cid ) = @_;
	my $evt;
	$self->logmark;
	my $circ = $self->cstorereq(
		'open-ils.cstore.direct.action.open_circulation.search',
		{ target_copy => $cid, stop_fines_time => undef } );
	$evt = OpenILS::Event->new('ACTION_CIRCULATION_NOT_FOUND') unless $circ;	
	return ($circ, $evt);
}

sub fetch_all_open_circulation {
	my( $self, $cid ) = @_;
	my $evt;
	$self->logmark;
	my $circ = $self->cstorereq(
		'open-ils.cstore.direct.action.open_circulation.search',
		{ target_copy => $cid, xact_finish => undef } );
	$evt = OpenILS::Event->new('ACTION_CIRCULATION_NOT_FOUND') unless $circ;	
	return ($circ, $evt);
}

my $copy_statuses;
sub copy_status_from_name {
	my( $self, $name ) = @_;
	$copy_statuses = $self->fetch_copy_statuses unless $copy_statuses;
	for my $status (@$copy_statuses) { 
		return $status if( $status->name =~ /$name/i );
	}
	return undef;
}

sub copy_status_to_name {
	my( $self, $sid ) = @_;
	$copy_statuses = $self->fetch_copy_statuses unless $copy_statuses;
	for my $status (@$copy_statuses) { 
		return $status->name if( $status->id == $sid );
	}
	return undef;
}


sub copy_status {
	my( $self, $arg ) = @_;
	return $arg if ref $arg;
	$copy_statuses = $self->fetch_copy_statuses unless $copy_statuses;
	my ($stat) = grep { $_->id == $arg } @$copy_statuses;
	return $stat;
}

sub fetch_open_transit_by_copy {
	my( $self, $copyid ) = @_;
	my($transit, $evt);
	$transit = $self->cstorereq(
		'open-ils.cstore.direct.action.transit_copy.search',
		{ target_copy => $copyid, dest_recv_time => undef });
	$evt = OpenILS::Event->new('ACTION_TRANSIT_COPY_NOT_FOUND') unless $transit;
	return ($transit, $evt);
}

sub unflesh_copy {
	my( $self, $copy ) = @_;
	return undef unless $copy;
	$copy->status( $copy->status->id ) if ref($copy->status);
	$copy->location( $copy->location->id ) if ref($copy->location);
	$copy->circ_lib( $copy->circ_lib->id ) if ref($copy->circ_lib);
	return $copy;
}

# un-fleshes a copy and updates it in the DB
# returns a DB_UPDATE_FAILED event on error
# returns undef on success
sub update_copy {
	my( $self, %params ) = @_;

	my $copy		= $params{copy}	|| die "update_copy(): copy required";
	my $editor	= $params{editor} || die "update_copy(): copy editor required";
	my $session = $params{session};

	$logger->debug("Updating copy in the database: " . $copy->id);

	$self->unflesh_copy($copy);
	$copy->editor( $editor );
	$copy->edit_date( 'now' );

	my $s;
	my $meth = 'open-ils.storage.direct.asset.copy.update';

	$s = $session->request( $meth, $copy )->gather(1) if $session;
	$s = $self->storagereq( $meth, $copy ) unless $session;

	$logger->debug("Update of copy ".$copy->id." returned: $s");

	return $self->DB_UPDATE_FAILED($copy) unless $s;
	return undef;
}

sub fetch_billable_xact {
	my( $self, $id ) = @_;
	my($xact, $evt);
	$logger->debug("Fetching billable transaction %id");
	$xact = $self->cstorereq(
		'open-ils.cstore.direct.money.billable_transaction.retrieve', $id );
	$evt = OpenILS::Event->new('MONEY_BILLABLE_TRANSACTION_NOT_FOUND') unless $xact;
	return ($xact, $evt);
}

sub fetch_billable_xact_summary {
	my( $self, $id ) = @_;
	my($xact, $evt);
	$logger->debug("Fetching billable transaction summary %id");
	$xact = $self->cstorereq(
		'open-ils.cstore.direct.money.billable_transaction_summary.retrieve', $id );
	$evt = OpenILS::Event->new('MONEY_BILLABLE_TRANSACTION_NOT_FOUND') unless $xact;
	return ($xact, $evt);
}

sub fetch_fleshed_copy {
	my( $self, $id ) = @_;
	my( $copy, $evt );
	$logger->info("Fetching fleshed copy $id");
	$copy = $self->cstorereq(
		"open-ils.cstore.direct.asset.copy.retrieve", $id,
		{ flesh => 1,
		  flesh_fields => { acp => [ qw/ circ_lib location status stat_cat_entries / ] }
		}
	);
	$evt = OpenILS::Event->new('ASSET_COPY_NOT_FOUND', id => $id) unless $copy;
	return ($copy, $evt);
}


# returns the org that owns the callnumber that the copy
# is attached to
sub fetch_copy_owner {
	my( $self, $copyid ) = @_;
	my( $copy, $cn, $evt );
	$logger->debug("Fetching copy owner $copyid");
	($copy, $evt) = $self->fetch_copy($copyid);
	return (undef,$evt) if $evt;
	($cn, $evt) = $self->fetch_callnumber($copy->call_number);
	return (undef,$evt) if $evt;
	return ($cn->owning_lib);
}

sub fetch_copy_note {
	my( $self, $id ) = @_;
	my( $note, $evt );
	$logger->debug("Fetching copy note $id");
	$note = $self->cstorereq(
		'open-ils.cstore.direct.asset.copy_note.retrieve', $id );
	$evt = OpenILS::Event->new('ASSET_COPY_NOTE_NOT_FOUND', id => $id ) unless $note;
	return ($note, $evt);
}

sub fetch_call_numbers_by_title {
	my( $self, $titleid ) = @_;
	$logger->info("Fetching call numbers by title $titleid");
	return $self->cstorereq(
		'open-ils.cstore.direct.asset.call_number.search.atomic', 
		{ record => $titleid, deleted => 'f' });
		#'open-ils.storage.direct.asset.call_number.search.record.atomic', $titleid);
}

sub fetch_copies_by_call_number {
	my( $self, $cnid ) = @_;
	$logger->info("Fetching copies by call number $cnid");
	return $self->cstorereq(
		'open-ils.cstore.direct.asset.copy.search.atomic', { call_number => $cnid, deleted => 'f' } );
		#'open-ils.storage.direct.asset.copy.search.call_number.atomic', $cnid );
}

sub fetch_user_by_barcode {
	my( $self, $bc ) = @_;
	my $cardid = $self->cstorereq(
		'open-ils.cstore.direct.actor.card.id_list', { barcode => $bc } );
	return (undef, OpenILS::Event->new('ACTOR_CARD_NOT_FOUND', barcode => $bc)) unless $cardid;
	my $user = $self->cstorereq(
		'open-ils.cstore.direct.actor.user.search', { card => $cardid } );
	return (undef, OpenILS::Event->new('ACTOR_USER_NOT_FOUND', card => $cardid)) unless $user;
	return ($user);
	
}


# ---------------------------------------------------------------------
# Updates and returns the patron penalties
# ---------------------------------------------------------------------
sub update_patron_penalties {
	my( $self, %args ) = @_;
	return $self->simplereq(
		'open-ils.penalty',
		'open-ils.penalty.patron_penalty.calculate', 
		{ update => 1, %args }
	);
}

sub fetch_bill {
	my( $self, $billid ) = @_;
	$logger->debug("Fetching billing $billid");
	my $bill = $self->cstorereq(
		'open-ils.cstore.direct.money.billing.retrieve', $billid );
	my $evt = OpenILS::Event->new('MONEY_BILLING_NOT_FOUND') unless $bill;
	return($bill, $evt);
}



my $ORG_TREE;
sub fetch_org_tree {
	my $self = shift;
	return $ORG_TREE if $ORG_TREE;
	return $ORG_TREE = OpenILS::Utils::CStoreEditor->new->search_actor_org_unit( 
		[
			{"parent_ou" => undef },
			{
				flesh				=> 2,
				flesh_fields	=> { aou =>  ['children'] },
				order_by       => { aou => 'name'}
			}
		]
	)->[0];
}

sub walk_org_tree {
	my( $self, $node, $callback ) = @_;
	return unless $node;
	$callback->($node);
	if( $node->children ) {
		$self->walk_org_tree($_, $callback) for @{$node->children};
	}
}

sub is_true {
	my( $self, $item ) = @_;
	return 1 if $item and $item !~ /^f$/i;
	return 0;
}


# This logic now lives in storage
sub __patron_money_owed {
	my( $self, $patronid ) = @_;
	my $ses = OpenSRF::AppSession->create('open-ils.storage');
	my $req = $ses->request(
		'open-ils.storage.money.billable_transaction.summary.search',
		{ usr => $patronid, xact_finish => undef } );

	my $total = 0;
	my $data;
	while( $data = $req->recv ) {
		$data = $data->content;
		$total += $data->balance_owed;
	}
	return $total;
}

sub patron_money_owed {
	my( $self, $userid ) = @_;
	my $ses = $self->start_db_session();
	my $val = $ses->request(
		'open-ils.storage.actor.user.total_owed', $userid)->gather(1);
	$self->rollback_db_session($ses);
	return $val;
}

sub patron_total_items_out {
	my( $self, $userid ) = @_;
	my $ses = $self->start_db_session();
	my $val = $ses->request(
		'open-ils.storage.actor.user.total_out', $userid)->gather(1);
	$self->rollback_db_session($ses);
	return $val;
}




#---------------------------------------------------------------------
# Returns  ($summary, $event) 
#---------------------------------------------------------------------
sub fetch_mbts {
	my $self = shift;
	my $id	= shift;
	my $editor = shift || OpenILS::Utils::CStoreEditor->new;

	$id = $id->id if (ref($id));

	my $xact = $editor->retrieve_money_billable_transaction(
		[
			$id, {	
				flesh => 1, 
				flesh_fields => { mbt => [ qw/billings payments grocery circulation/ ] } 
			}
		]
	) or return (undef, $editor->event);

	return $self->make_mbts($xact);
}


#---------------------------------------------------------------------
# Given a list of money.billable_transaction objects, this creates
# transaction summary objects for each
#--------------------------------------------------------------------
sub make_mbts {
	my $self = shift;
	my @xacts = @_;

	my @mbts;
	for my $x (@xacts) {

		my $s = new Fieldmapper::money::billable_transaction_summary;

		$s->id( $x->id );
		$s->usr( $x->usr );
		$s->xact_start( $x->xact_start );
		$s->xact_finish( $x->xact_finish );
		
		my $to = 0;
		my $lb = undef;
		for my $b (@{ $x->billings }) {
			next if ($self->is_true($b->voided));
			$to += ($b->amount * 100);
			$lb ||= $b->billing_ts;
			if ($b->billing_ts ge $lb) {
				$lb = $b->billing_ts;
				$s->last_billing_note($b->note);
				$s->last_billing_ts($b->billing_ts);
				$s->last_billing_type($b->billing_type);
			}
		}

		$s->total_owed( sprintf('%0.2f', $to / 100 ) );
		
		my $tp = 0;
		my $lp = undef;
		for my $p (@{ $x->payments }) {
			next if ($self->is_true($p->voided));
			$tp += ($p->amount * 100);
			$lp ||= $p->payment_ts;
			if ($p->payment_ts ge $lp) {
				$lp = $p->payment_ts;
				$s->last_payment_note($p->note);
				$s->last_payment_ts($p->payment_ts);
				$s->last_payment_type($p->payment_type);
			}
		}

		$s->total_paid( sprintf('%0.2f', $tp / 100 ) );
		$s->balance_owed( sprintf('%0.2f', ($to - $tp) / 100) );
		$s->xact_type('grocery') if ($x->grocery);
		$s->xact_type('circulation') if ($x->circulation);

		$logger->debug("Created mbts with balance_owed = ". $s->balance_owed);
		
		push @mbts, $s;
	}
		
	return @mbts;
}
		
		
sub ou_ancestor_setting_value {
    my $obj = ou_ancestor_setting(@_);
    return ($obj) ? $obj->{value} : undef;
}

sub ou_ancestor_setting {
    my( $self, $orgid, $name, $e ) = @_;
    $e = $e || OpenILS::Utils::CStoreEditor->new;

    do {
        my $setting = $e->search_actor_org_unit_setting({org_unit=>$orgid, name=>$name})->[0];

        if( $setting ) {
            $logger->info("found org_setting $name at org $orgid : " . $setting->value);
            return { org => $orgid, value => OpenSRF::Utils::JSON->JSON2perl($setting->value) };
        }

        my $org = $e->retrieve_actor_org_unit($orgid) or return $e->event;
        $orgid = $org->parent_ou or return undef;

    } while(1);

    return undef;
}	
		

# returns the ISO8601 string representation of the requested epoch in GMT
sub epoch2ISO8601 {
    my( $self, $epoch ) = @_;
    my ($sec,$min,$hour,$mday,$mon,$year) = gmtime($epoch);
    $year += 1900; $mon += 1;
    my $date = sprintf(
        '%s-%0.2d-%0.2dT%0.2d:%0.2d:%0.2d-00',
        $year, $mon, $mday, $hour, $min, $sec);
    return $date;
}
			
sub find_highest_perm_org {
	my ( $self, $perm, $userid, $start_org, $org_tree ) = @_;
	my $org = $self->find_org($org_tree, $start_org );

	my $lastid = -1;
	while( $org ) {
		last if ($self->check_perms( $userid, $org->id, $perm )); # perm failed
		$lastid = $org->id;
		$org = $self->find_org( $org_tree, $org->parent_ou() );
	}

	return $lastid;
}


sub find_highest_work_orgs {
    my($self, $e, $perm, $options) = @_;
    my $work_orgs = $self->get_user_work_ou_ids($e, $e->requestor->id);
    $logger->debug("found work orgs @$work_orgs");
	$options ||= {};

    my @allowed_orgs;
	my $org_tree = $self->get_org_tree();
    my $org_types = $self->get_org_types();

    # use the first work org to determine the highest depth at which 
    # the user has the requested permission
    my $first_org = shift @$work_orgs;
    my $high_org_id = $self->find_highest_perm_org($perm, $e->requestor->id, $first_org, $org_tree);
    $logger->debug("found highest work org $high_org_id");

    
    return [] if $high_org_id == -1; # not allowed anywhere

    my $high_org = $self->find_org($org_tree, $high_org_id);
    my ($high_org_type) = grep { $_->id == $high_org->ou_type } @$org_types;
    my $org_depth = $high_org_type->depth;

	if($$options{descendants}) {
		push(@allowed_orgs, @{$self->get_org_descendants($high_org_id, $org_depth)});
	} else {
		push(@allowed_orgs, $high_org_id);
	}

	return \@allowed_orgs if $org_depth == 0;

    for my $org (@$work_orgs) {

        $logger->debug("work org looking at $org");
		my $org_list = $self->get_org_full_path($org, $org_depth);

		my $found = 0;
        for my $sub_org (@$org_list) {
			if(not $found) {
				$logger->debug("work org looking at sub-org $sub_org");
				my $org_unit = $self->find_org($org_tree, $sub_org);
				my ($ou_type) = grep { $_->id == $org_unit->ou_type } @$org_types;
				if($ou_type->depth >= $org_depth) {
					push(@allowed_orgs, $sub_org);
					$found = 1;
				}
			} else {
				last unless $$options{descendants}; 
				push(@allowed_orgs, $sub_org);
			}
        }
    }

    my %de_dupe;
    $de_dupe{$_} = 1 for @allowed_orgs;
    return [keys %de_dupe];
}


sub get_user_work_ou_ids {
    my($self, $e, $userid) = @_;
    my $work_orgs = $e->json_query({
        select => {puwoum => ['work_ou']},
        from => 'puwoum',
        where => {usr => $e->requestor->id}});

    return [] unless @$work_orgs;
    my @work_orgs;
    push(@work_orgs, $_->{work_ou}) for @$work_orgs;

    return \@work_orgs;
}


my $org_types;
sub get_org_types {
	my($self, $client) = @_;
	return $org_types if $org_types;
	return $org_types = OpenILS::Utils::CStoreEditor->new->retrieve_all_actor_org_unit_type();
}

sub get_org_tree {
	my $self = shift;
	my $locale = shift || '';
	my $cache = OpenSRF::Utils::Cache->new("global", 0);
	my $tree = $cache->get_cache("orgtree.$locale");
	return $tree if $tree;

	my $ses = OpenILS::Utils::CStoreEditor->new;
	$ses->session->session_locale($locale);
	$tree = $ses->search_actor_org_unit( 
		[
			{"parent_ou" => undef },
			{
				flesh				=> -1,
				flesh_fields	=> { aou =>  ['children'] },
				order_by			=> { aou => 'name'}
			}
		]
	)->[0];

	$cache->put_cache("orgtree.$locale", $tree);
	return $tree;
}

sub get_org_descendants {
	my($self, $org_id, $depth) = @_;

	my $select = {
		transform => 'actor.org_unit_descendants',
		column => 'id',
		result_field => 'id',
	};
	$select->{params} = [$depth] if defined $depth;

	my $org_list = OpenILS::Utils::CStoreEditor->new->json_query({
		select => {aou => [$select]},
        from => 'aou',
		where => {id => $org_id}
	});
	my @orgs;
	push(@orgs, $_->{id}) for @$org_list;
	return \@orgs;
}

sub get_org_ancestors {
	my($self, $org_id, $depth) = @_;
	$depth ||= 0;

	my $org_list = OpenILS::Utils::CStoreEditor->new->json_query({
		select => {
			aou => [{
				transform => 'actor.org_unit_ancestors',
				column => 'id',
				result_field => 'id',
				params => [$depth]
			}],
		},
		from => 'aou',
		where => {id => $org_id}
	});

	my @orgs;
	push(@orgs, $_->{id}) for @$org_list;
	return \@orgs;
}

sub get_org_full_path {
	my($self, $org_id, $depth) = @_;
	$depth ||= 0;

	my $org_list = OpenILS::Utils::CStoreEditor->new->json_query({
		select => {
			aou => [{
				transform => 'actor.org_unit_full_path',
				column => 'id',
				result_field => 'id',
				params => [$depth]
			}],
		},
		from => 'aou',
		where => {id => $org_id}
	});

	my @orgs;
	push(@orgs, $_->{id}) for @$org_list;
	return \@orgs;
}

# returns the user's configured locale as a string.  Defaults to en-US if none is configured.
sub get_user_locale {
	my($self, $user_id, $e) = @_;
	$e ||= OpenILS::Utils::CStoreEditor->new;

	# first, see if the user has an explicit locale set
	my $setting = $e->search_actor_user_setting(
		{usr => $user_id, name => 'global.locale'})->[0];
	return OpenSRF::Utils::JSON->JSON2perl($setting->value) if $setting;

	my $user = $e->retrieve_actor_user($user_id) or return $e->event;
	return $self->get_org_locale($user->home_ou, $e);
}

# returns org locale setting
sub get_org_locale {
	my($self, $org_id, $e) = @_;
	$e ||= OpenILS::Utils::CStoreEditor->new;

	my $locale;
	if(defined $org_id) {
		$locale = $self->ou_ancestor_setting_value($org_id, 'global.default_locale', $e);
		return $locale if $locale;
	}

	# system-wide default
	my $sclient = OpenSRF::Utils::SettingsClient->new;
	$locale = $sclient->config_value('default_locale');
    return $locale if $locale;

	# if nothing else, fallback to locale=cowboy
	return 'en-US';
}


# xml-escape non-ascii characters
sub entityize { 
    my($self, $string, $form) = @_;
	$form ||= "";

	if ($form eq 'D') {
		$string = NFD($string);
	} else {
		$string = NFC($string);
	}

	# Convert raw ampersands to ampersand entities
	$string =~ s/&(?!\S+;)/&amp;/gso;

	$string =~ s/([\x{0080}-\x{fffd}])/sprintf('&#x%X;',ord($1))/sgoe;
	return $string;
}


sub get_copy_price {
	my($self, $e, $copy, $volume) = @_;

	$copy->price(0) if $copy->price < 0;

	return $copy->price if $copy->price and $copy->price > 0;


	my $owner;
	if(ref $volume) {
		if($volume->id == OILS_PRECAT_CALL_NUMBER) {
			$owner = $copy->circ_lib;
		} else {
			$owner = $volume->owning_lib;
		}
	} else {
		if($copy->call_number == OILS_PRECAT_CALL_NUMBER) {
			$owner = $copy->circ_lib;
		} else {
			$owner = $e->retrieve_asset_call_number($copy->call_number)->owning_lib;
		}
	}

	my $default_price = $self->ou_ancestor_setting_value(
		$owner, OILS_SETTING_DEF_ITEM_PRICE, $e) || 0;

	return $default_price unless defined $copy->price;

	# price is 0.  Use the default?
    my $charge_on_0 = $self->ou_ancestor_setting_value(
        $owner, OILS_SETTING_CHARGE_LOST_ON_ZERO, $e) || 0;

	return $default_price if $charge_on_0;
	return 0;
}

1;

