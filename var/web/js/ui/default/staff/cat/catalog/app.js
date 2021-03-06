/**
 * TPAC Frame App
 *
 * currently, this app doesn't use routes for each sub-ui, because 
 * reloading the catalog each time is sloooow.  better so far to 
 * swap out divs w/ ng-if / ng-show / ng-hide as needed.
 *
 */

angular.module('egCatalogApp', ['ui.bootstrap','ngRoute','egCoreMod','egGridMod', 'egMarcMod'])

.config(function($routeProvider, $locationProvider, $compileProvider) {
    $locationProvider.html5Mode(true);
    $compileProvider.aHrefSanitizationWhitelist(/^\s*(https?|blob):/); // grid export

    var resolver = {delay : 
        ['egStartup', function(egStartup) {return egStartup.go()}]}

    $routeProvider.when('/cat/catalog/index', {
        templateUrl: './cat/catalog/t_catalog',
        controller: 'CatalogCtrl',
        resolve : resolver
    });

    $routeProvider.when('/cat/catalog/retrieve_by_id', {
        templateUrl: './cat/catalog/t_retrieve_by_id',
        controller: 'CatalogRecordRetrieve',
        resolve : resolver
    });

    $routeProvider.when('/cat/catalog/retrieve_by_tcn', {
        templateUrl: './cat/catalog/t_retrieve_by_tcn',
        controller: 'CatalogRecordRetrieve',
        resolve : resolver
    });

    // create some catalog page-specific mappings
    $routeProvider.when('/cat/catalog/record/:record_id', {
        templateUrl: './cat/catalog/t_catalog',
        controller: 'CatalogCtrl',
        resolve : resolver
    });

    // create some catalog page-specific mappings
    $routeProvider.when('/cat/catalog/record/:record_id/:record_tab', {
        templateUrl: './cat/catalog/t_catalog',
        controller: 'CatalogCtrl',
        resolve : resolver
    });

    $routeProvider.otherwise({redirectTo : '/cat/catalog/index'});
})


/**
 * */
.controller('CatalogRecordRetrieve',
       ['$scope','$routeParams','$location','$q','egCore',
function($scope , $routeParams , $location , $q , egCore ) {

    $scope.focusMe = true;

    // jump to the patron checkout UI
    function loadRecord(record_id) {
        $location
        .path('/cat/catalog/record/' + record_id);
    }

    $scope.submitId = function(args) {
        $scope.recordNotFound = null;
        if (!args.record_id) return;

        // blur so next time it's set to true it will re-apply select()
        $scope.selectMe = false;

        return loadRecord(args.record_id);
    }

    $scope.submitTCN = function(args) {
        $scope.recordNotFound = null;
        $scope.moreRecordsFound = null;
        if (!args.record_tcn) return;

        // blur so next time it's set to true it will re-apply select()
        $scope.selectMe = false;

        // lookup TCN
        egCore.net.request(
            'open-ils.search',
            'open-ils.search.biblio.tcn',
            args.record_tcn)

        .then(function(resp) { // get_barcodes

            if (evt = egCore.evt.parse(resp)) {
                alert(evt); // FIXME
                return;
            }

            if (!resp.count) {
                $scope.recordNotFound = args.record_tcn;
                $scope.selectMe = true;
                return;
            }

            if (resp.count > 1) {
                $scope.moreRecordsFound = args.record_tcn;
                $scope.selectMe = true;
                return;
            }

            var record_id = resp.ids[0];
            return loadRecord(record_id);
        });
    }

}])

.controller('CatalogCtrl',
       ['$scope','$routeParams','$location','$q','egCore','egHolds',
        'egGridDataProvider','egHoldGridActions',
function($scope , $routeParams , $location , $q , egCore , egHolds, 
         egGridDataProvider , egHoldGridActions) {

    // set record ID on page load if available...
    $scope.record_id = $routeParams.record_id;

    // Set the "last bib" cookie, if we have that
    if ($scope.record_id)
        egCore.hatch.setLocalItem("eg.cat.last_record_retrieved", $scope.record_id);

    // also set it when the iframe changes to a new record
    $scope.handle_page = function(url) {

        if (!url || url == 'about:blank') {
            // nothing loaded.  If we already have a record ID, leave it.
            return;
        }

        var match = url.match(/\/+opac\/+record\/+(\d+)/);
        if (match) {
            $scope.record_id = match[1];
            egCore.hatch.setLocalItem("eg.cat.last_record_retrieved", $scope.record_id);

            // force the record_id to show up in the page.  
            // not sure why a $digest isn't occuring here.
            try { $scope.$apply() } catch(E) {}
        } else {
            delete $scope.record_id;
        }

        if ($scope.record_id) {
            var default_tab = egCore.hatch.getLocalItem( 'eg.cat.default_record_tab' );
            tab = $routeParams.record_tab || default_tab || 'catalog';
        } else {
            tab = $routeParams.record_tab || 'catalog';
        }
        $scope.set_record_tab(tab);
    }

    // xulG catalog handlers
    $scope.handlers = { }

    // ------------------------------------------------------------------
    // Holds 
    var provider = egGridDataProvider.instance({});
    $scope.hold_grid_data_provider = provider;
    $scope.grid_actions = egHoldGridActions;
    $scope.hold_grid_controls = {};

    var hold_ids = []; // current list of holds
    function fetchHolds(offset, count) {
        var ids = hold_ids.slice(offset, offset + count);
        return egHolds.fetch_holds(ids).then(null, null,
            function(hold_data) { 
                return hold_data;
            }
        );
    }

    provider.get = function(offset, count) {
        if ($scope.record_tab != 'holds') return $q.when();
        var deferred = $q.defer();
        hold_ids = []; // no caching ATM

        // fetch the IDs
        egCore.net.request(
            'open-ils.circ',
            'open-ils.circ.holds.retrieve_all_from_title',
            egCore.auth.token(), $scope.record_id, 
            {pickup_lib : egCore.org.descendants($scope.pickup_ou.id(), true)}
        ).then(
            function(hold_data) {
                angular.forEach(hold_data, function(list, type) {
                    hold_ids = hold_ids.concat(list);
                });
                fetchHolds(offset, count).then(
                    deferred.resolve, null, deferred.notify);
            }
        );

        return deferred.promise;
    }

    $scope.detail_view = function(action, user_data, items) {
        if (h = items[0]) {
            $scope.detail_hold_id = h.hold.id();
        }
    }

    $scope.list_view = function(items) {
         $scope.detail_hold_id = null;
    }

    // refresh the list of record holds when the pickup lib is changed.
    $scope.pickup_ou = egCore.org.get(egCore.auth.user().ws_ou());
    $scope.pickup_ou_changed = function(org) {
        $scope.pickup_ou = org;
        provider.refresh();
    }

    $scope.print_holds = function() {
        var holds = [];
        angular.forEach($scope.hold_grid_controls.allItems(), function(item) {
            holds.push({
                hold : egCore.idl.toHash(item.hold),
                patron_last : item.patron_last,
                patron_alias : item.patron_alias,
                patron_barcode : item.patron_barcode,
                copy : egCore.idl.toHash(item.copy),
                volume : egCore.idl.toHash(item.volume),
                title : item.mvr.title(),
                author : item.mvr.author()
            });
        });

        egCore.print.print({
            context : 'receipt', 
            template : 'holds_for_bib', 
            scope : {holds : holds}
        });
    }

    $scope.mark_hold_transfer_dest = function() {
        egCore.hatch.setLocalItem(
            'eg.circ.hold.title_transfer_target', $scope.record_id);
    }

    // UI presents this option as "all holds"
    $scope.transfer_holds_to_marked = function() {
        var hold_ids = $scope.hold_grid_controls.allItems().map(
            function(hold_data) {return hold_data.hold.id()});
        egHolds.transfer_to_marked_title(hold_ids);
    }

    // ------------------------------------------------------------------
    // Initialize the selected tab

    function init_cat_url() {
        // Set the initial catalog URL.  This only happens once.
        // The URL is otherwise generated through user navigation.
        if ($scope.catalog_url) return; 

        var url = $location.absUrl().replace(/\/staff.*/, '/opac/advanced');

        // A record ID in the path indicates a request for the record-
        // specific page.
        if ($routeParams.record_id) {
            url = url.replace(/advanced/, '/record/' + $scope.record_id);
        }

        $scope.catalog_url = url;
    }

    $scope.set_record_tab = function(tab) {
        $scope.record_tab = tab;

        switch(tab) {

            case 'catalog':
                init_cat_url();
                break;

            case 'holds':
                $scope.detail_hold_record_id = $scope.record_id; 
                // refresh the holds grid
                provider.refresh();
                break;
        }
    }

    $scope.set_default_record_tab = function() {
        egCore.hatch.setLocalItem(
            'eg.cat.default_record_tab', $scope.record_tab);
    }

    var tab;
    if ($scope.record_id) {
        var default_tab = egCore.hatch.getLocalItem( 'eg.cat.default_record_tab' );
        tab = $routeParams.record_tab || default_tab || 'catalog';
    } else {
        tab = $routeParams.record_tab || 'catalog';
    }
    $scope.set_record_tab(tab);

}])
 
