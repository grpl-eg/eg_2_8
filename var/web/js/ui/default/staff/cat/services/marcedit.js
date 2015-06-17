/**
 *  A MARC editor...
 */

angular.module('egMarcMod', ['egCoreMod', 'ui.bootstrap'])

.directive("egContextMenuItem", ['$timeout',function ($timeout) {
    return {
        restrict: 'E',
        replace: true,
        template: '<li><a ng-click="setContent(item.value,item.action)">{{item.label}}</a></li>',
        scope: { item: '=', content: '=' },
        controller: ['$scope','$element',
            function ($scope , $element) {
                if (!$scope.item.label) $scope.item.label = $scope.item.value;
                if ($scope.item.divider) {
                    $element.style.borderTop = 'solid 1px';
                }

                $scope.setContent = function (v, a) {
                    var replace_with = v;
                    if (a) replace_with = a($scope,$element,$scope.item.value,$scope.$parent.$parent.content);
                    $timeout(function(){
                        $scope.$parent.$parent.$apply(function(){
                            $scope.$parent.$parent.content = replace_with
                        })
                    }, 0);
                    $($element).parent().css({display: 'none'});
                }
            }
        ]
    }
}])

.directive("egMarcEditEditable", ['$timeout', '$compile', '$document', function ($timeout, $compile, $document) {
    return {
        restrict: 'E',
        replace: true,
        template: '<input '+
                      'style="font-family: \'Lucida Console\', Monaco, monospace;" '+
                      'ng-model="content" '+
                      'size="{{content.length * 1.1}}" '+
                      'maxlength="{{max}}" '+
                      'class="" '+
                      'type="text" '+
                  '/>',
        scope: {
            field: '=',
            onKeydown: '=',
            subfield: '=',
            content: '=',
            contextItemContainer: '@',
            max: '@',
            itype: '@'
        },
        controller : ['$scope',
            function ( $scope ) {

/* XXX Example, for testing.  We'll get this from the tag-table services for realz
 *
                if (!$scope.contextItemContainer) {
                    $scope.contextItemContainer = "default_context";
                    $scope[$scope.contextItemContainer] = [
                        { value: 'a' },
                        { value: 'b' },
                        { value: 'c' },
                    ];
                }

 *
 */

                if ($scope.contextItemContainer)
                    $scope.item_container = $scope[$scope.contextItemContainer];

                $scope.showContext = function (event) {
                    if ($scope.context_menu_element) {
                        console.log('Reshowing context menu...');
                        $($scope.context_menu_element).css({ display: 'block', top: event.pageY, left: event.pageX });
                        $('body').on('click.context_menu',function() {
                            $($scope.context_menu_element).css('display','none');
                            $('body').off('click.context_menu');
                        });
                        return false;
                    }

                    if (angular.isArray($scope.item_container)) { // we have a list of values or transforms
                        console.log('Showing context menu...');

                        var tmpl = 
                            '<ul class="dropdown-menu" role="menu">'+
                                '<eg-context-menu-item ng-repeat="item in item_container" item="item" content="content"/>'+
                            '</ul>';
            
                        var tnode = angular.element(tmpl);
                        $document.find('body').append(tnode);

                        $(tnode).css({
                            display: 'block',
                            top: event.pageY,
                            left: event.pageX
                        });

                        $scope.context_menu_element = tnode;

                        $timeout(function() {
                            var e = $compile(tnode)($scope);
                        }, 0);


                        $('body').on('click.context_menu',function() {
                            $(tnode).css('display','none');
                            $('body').off('click.context_menu');
                        });

                        return false;
                    }
            
                    return true;
                }

            }
        ],
        link: function (scope, element, attrs) {

            if (scope.onKeydown) element.bind('keydown', {scope : scope}, scope.onKeydown);

            element.bind('change', function (e) { element.size = scope.max || parseInt(scope.content.length * 1.1) });

            if (scope.contextItemContainer && angular.isArray(scope[scope.contextItemContainer]))
                element.bind('contextmenu', scope.showContext);
        }
    }
}])

.directive("egMarcEditSubfield", function () {
    return {
        transclude: true,
        restrict: 'E',
        template: '<span>'+
                    '<span><label class="marcedit marcsfcodedelimiter"'+
                        'for="r{{field.record.subfield(\'901\',\'c\')[1]}}f{{field.position}}s{{subfield[2]}}code" '+
                        '>‡</label><eg-marc-edit-editable '+
                        'itype="sfc" '+
                        'class="marcedit marcsf marcsfcode" '+
                        'field="field" '+
                        'subfield="subfield" '+
                        'content="subfield[0]" '+
                        'max="1" '+
                        'on-keydown="onKeydown" '+
                        'id="r{{field.record.subfield(\'901\',\'c\')[1]}}f{{field.position}}s{{subfield[2]}}code" '+
                    '/></span>'+
                    '<span><eg-marc-edit-editable '+
                        'itype="sfv" '+
                        'class="marcedit marcsf marcsfvalue" '+
                        'field="field" '+
                        'subfield="subfield" '+
                        'content="subfield[1]" '+
                        'on-keydown="onKeydown" '+
                        'id="r{{field.record.subfield(\'901\',\'c\')[1]}}f{{field.position}}s{{subfield[2]}}value" '+
                    '/></span>'+
                  '</span>',
        scope: { field: "=", subfield: "=", onKeydown: '=' },
        replace: true
    }
})

.directive("egMarcEditInd", function () {
    return {
        transclude: true,
        restrict: 'E',
        template: '<span><eg-marc-edit-editable '+
                      'itype="ind" '+
                      'class="marcedit marcind" '+
                      'field="field" '+
                      'content="ind" '+
                      'max="1" '+
                      'on-keydown="onKeydown" '+
                      'id="r{{field.record.subfield(\'901\',\'c\')[1]}}f{{field.position}}i{{indNumber}}"'+
                      '/></span>',
        scope: { ind : '=', field: '=', onKeydown: '=', indNumber: '@' },
        replace: true
    }
})

.directive("egMarcEditTag", function () {
    return {
        transclude: true,
        restrict: 'E',
        template: '<span><eg-marc-edit-editable '+
                      'itype="tag" '+
                      'class="marcedit marctag" '+
                      'field="field" '+
                      'content="tag" '+
                      'max="3" '+
                      'on-keydown="onKeydown" '+
                      'id="r{{field.record.subfield(\'901\',\'c\')[1]}}f{{field.position}}tag"'+
                      '/></span>',
        scope: { tag : '=', field: '=', onKeydown: '=' },
        replace: true
    }
})

.directive("egMarcEditDatafield", function () {
    return {
        transclude: true,
        restrict: 'E',
        template: '<div>'+
                    '<span><eg-marc-edit-tag field="field" tag="field.tag" on-keydown="onKeydown"/></span>'+
                    '<span><eg-marc-edit-ind field="field" ind="field.ind1" on-keydown="onKeydown" ind-number="1"/></span>'+
                    '<span><eg-marc-edit-ind field="field" ind="field.ind2" on-keydown="onKeydown" ind-number="2"/></span>'+
                    '<span><eg-marc-edit-subfield ng-repeat="subfield in field.subfields" subfield="subfield" field="field" on-keydown="onKeydown"/></span>'+
                  '</div>',
        scope: { field: "=", onKeydown: '=' },
        replace: true
    }
})

.directive("egMarcEditControlfield", function () {
    return {
        transclude: true,
        restrict: 'E',
        template: '<div>'+
                    '<span><eg-marc-edit-tag field="field" tag="field.tag" on-keydown="onKeydown"/></span>'+
                    '<span><eg-marc-edit-editable '+
                      'itype="cfld" '+
                      'field="field" '+
                      'class="marcedit marcdata" '+
                      'content="field.data" '+
                      'on-keydown="onKeydown" '+
                      'id="r{{field.record.subfield(\'901\',\'c\')[1]}}f{{field.position}}data"'+
                      '/></span>'+
                  '</div>',
        scope: { field: "=", onKeydown: '=' }
    }
})

.directive("egMarcEditLeader", function () {
    return {
        transclude: true,
        restrict: 'E',
        template: '<div>'+
                    '<span><eg-marc-edit-editable '+
                      'class="marcedit marctag" '+
                      'content="tag" '+
                      'on-keydown="onKeydown" '+
                      'id="leadertag" '+
                      'disabled="disabled"'+
                      '/></span>'+
                    '<span><eg-marc-edit-editable '+
                      'class="marcedit marcdata" '+
                      'itype="ldr" '+
                      'max="{{record.leader.length}}" '+
                      'content="record.leader" '+
                      'id="r{{record.subfield(\'901\',\'c\')[1]}}leaderdata" '+
                      'on-keydown="onKeydown"'+
                      '/></span>'+
                  '</div>',
        controller : ['$scope',
            function ( $scope ) {
                $scope.tag = 'LDR';
            }
        ],
        scope: { record: "=", onKeydown: '=' }
    }
})

/// TODO: fixed field editor and such
.directive("egMarcEditRecord", function () {
    return {
        templateUrl : './cat/share/t_marcedit',
        restrict: 'E',
        replace: true,
        scope: { recordId : '=', recordType : '@', maxUndo : '@' },
        link: function (scope, element, attrs) {

            element.bind('click', function(e) {;
                scope.current_event_target = $(e.target).attr('id');
                if (scope.current_event_target) {
                    console.log('Recording click event on ' + scope.current_event_target);
                    scope.current_event_target_cursor_pos =
                        e.target.selectionDirection=='backward' ?
                            e.target.selectionStart :
                            e.target.selectionEnd;
                }
            });

        },
        controller : ['$timeout','$scope','egCore',
            function ( $timeout , $scope , egCore ) {

                $scope.bib_source = null;
                $scope.record_type = $scope.recordType || 'bre';
                $scope.max_undo = $scope.maxUndo || 100;
                $scope.record_undo_stack = [];
                $scope.record_redo_stack = [];
                $scope.in_undo = false;
                $scope.in_redo = false;
                $scope.record = new MARC.Record();
                $scope.save_stack_depth = 0;
                $scope.controlfields = [];
                $scope.datafields = [];

                $scope.onKeydown = function (event) {
                    var event_return = true;

                    console.log(
                        'keydown: which='+event.which+
                        ', ctrlKey='+event.ctrlKey+
                        ', shiftKey='+event.shiftKey+
                        ', altKey='+event.altKey+
                        ', metaKey='+event.altKey
                    );

                    if (event.which == 89 && event.ctrlKey) { // ctrl+y, redo
                        event_return = $scope.processRedo();
                    } else if (event.which == 90 && event.ctrlKey) { // ctrl+z, undo
                        event_return = $scope.processUndo();
                    } else if ((event.which == 68 || event.which == 73) && event.ctrlKey) { // ctrl+d or ctrl+i, insert subfield

                        var element = $(event.target);
                        var new_sf, index_sf, move_data;

                        if (element.hasClass('marcsfvalue')) {
                            index_sf = event.data.scope.subfield[2];
                            new_sf = index_sf + 1;

                            var start = event.target.selectionStart;
                            var end = event.target.selectionEnd - event.target.selectionStart ?
                                    event.target.selectionEnd :
                                    event.target.value.length;

                            move_data = event.target.value.substring(start,end);

                        } else if (element.hasClass('marcsfcode')) {
                            index_sf = event.data.scope.subfield[2];
                            new_sf = index_sf + 1;
                        } else if (element.hasClass('marctag') || element.hasClass('marcind')) {
                            index_sf = 0;
                            new_sf = index_sf;
                        }

                        $scope.current_event_target = 'r' + $scope.recordId +
                                                      'f' + event.data.scope.field.position + 
                                                      's' + new_sf + 'code';

                        event.data.scope.field.subfields.forEach(function(sf) {
                            if (sf[2] >= new_sf) sf[2]++;
                            if (sf[2] == index_sf) sf[1] = event.target.value.substring(0,start) + event.target.value.substring(end);
                        });
                        event.data.scope.field.subfields.splice(
                            new_sf,
                            0,
                            [' ', move_data, new_sf ]
                        );

                        $scope.current_event_target_cursor_pos = 0;
                        $scope.current_event_target_cursor_pos_end = 1;

                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.which == 117 && event.shiftKey) { // shift + F6, insert 006
                        event.data.scope.field.record.insertOrderedFields(
                            new MARC.Field({
                                tag : '006',
                                data : '                                        '
                            })
                        );

                        $scope.force_render = true;
                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.which == 118 && event.shiftKey) { // shift + F7, insert 007
                        event.data.scope.field.record.insertOrderedFields(
                            new MARC.Field({
                                tag : '007',
                                data : '                                        '
                            })
                        );

                        $scope.force_render = true;
                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.which == 119 && event.shiftKey) { // shift + F8, insert/replace 008
                        var new_008_data = event.data.scope.field.record.generate008();


                        var old_008s = event.data.scope.field.record.field('008',true);
                        old_008s.forEach(function(o) {
                            var domnode = $('#r'+o.record.subfield('901','c')[1] + 'f' + o.position);
                            domnode.scope().$destroy();
                            domnode.remove();
                            event.data.scope.field.record.deleteFields(o);
                        });

                        event.data.scope.field.record.insertOrderedFields(
                            new MARC.Field({
                                tag : '008',
                                data : new_008_data
                            })
                        );

                        $scope.force_render = true;
                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.which == 13 && event.ctrlKey) { // ctrl+enter, insert datafield

                        var element = $(event.target);

                        var index_field = event.data.scope.field.position;
                        var new_field = index_field + 1;

                        event.data.scope.field.record.insertFieldsAfter(
                            event.data.scope.field,
                            new MARC.Field({
                                tag : '999',
                                subfields : [[' ','',0]]
                            })
                        );

                        $scope.current_event_target = 'r' + $scope.recordId +
                                                      'f' + new_field + 'tag';

                        $scope.current_event_target_cursor_pos = 0;
                        $scope.current_event_target_cursor_pos_end = 3;
                        $scope.force_render = true;

                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.which == 46 && event.ctrlKey) { // ctrl+del, remove field

                        var del_field = event.data.scope.field.position;

                        var domnode = $('#r'+event.data.scope.field.record.subfield('901','c')[1] + 'f' + del_field);

                        event.data.scope.field.record.deleteFields(
                            event.data.scope.field
                        );

                        domnode.scope().$destroy();
                        domnode.remove();

                        $scope.current_event_target = 'r' + $scope.recordId +
                                                      'f' + del_field + 'tag';

                        $scope.current_event_target_cursor_pos = 0;
                        $scope.current_event_target_cursor_pos_end = 0
                        $scope.force_render = true;

                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.which == 46 && event.shiftKey && $(event.target).hasClass('marcsf')) { // shift+del, remove subfield

                        var sf = event.data.scope.subfield[2] - 1;
                        if (sf == -1) sf = 0;

                        event.data.scope.field.deleteExactSubfields(
                            event.data.scope.subfield
                        );

                        if (!event.data.scope.field.subfields[sf]) {
                            $scope.current_event_target = 'r' + $scope.recordId +
                                                          'f' + event.data.scope.field.position + 
                                                          'tag';
                        } else {
                            $scope.current_event_target = 'r' + $scope.recordId +
                                                          'f' + event.data.scope.field.position + 
                                                          's' + sf + 'value';
                        }

                        $scope.current_event_target_cursor_pos = 0;
                        $scope.current_event_target_cursor_pos_end = 0;
                        $scope.force_render = true;

                        $timeout(function(){$scope.$digest()}).then(setCaret);

                        event_return = false;

                    } else if (event.keyCode == 38) {
                        if (event.ctrlKey) { // copy the field up
                            var index_field = event.data.scope.field.position;

                            var field_obj;
                            if (event.data.scope.field.isControlfield()) {
                                field_obj = new MARC.Field({
                                    tag : event.data.scope.field.tag,
                                    data : event.data.scope.field.data
                                });
                            } else {
                                var sf_clone = [];
                                for (var i in event.data.scope.field.subfields) {
                                    sf_clone.push(event.data.scope.field.subfields[i].slice());
                                }
                                field_obj = new MARC.Field({
                                    tag : event.data.scope.field.tag,
                                    ind1 : event.data.scope.field.ind1,
                                    ind2 : event.data.scope.field.ind2,
                                    subfields : sf_clone
                                });
                            }


                            event.data.scope.field.record.insertFieldsBefore(
                                event.data.scope.field,
                                field_obj
                            );

                            $scope.current_event_target = 'r' + $scope.recordId +
                                                          'f' + index_field + 'tag';

                            $scope.current_event_target_cursor_pos = 0;
                            $scope.current_event_target_cursor_pos_end = 3;
                            $scope.force_render = true;

                            $timeout(function(){$scope.$digest()}).then(setCaret);

                        } else { // jump to prev field
                            if (event.data.scope.field.position > 0) {
                                $timeout(function(){
                                    $scope.current_event_target_cursor_pos = 0;
                                    $scope.current_event_target_cursor_pos_end = 0;
                                    $scope.current_event_target = 'r' + $scope.recordId +
                                                                  'f' + (event.data.scope.field.position - 1) +
                                                                  'tag';
                                }).then(setCaret);
                            }
                        }

                        event_return = false;

                    } else if (event.keyCode == 40) { // down arrow...
                        if (event.ctrlKey) { // copy the field down

                            var index_field = event.data.scope.field.position;
                            var new_field = index_field + 1;

                            var field_obj;
                            if (event.data.scope.field.isControlfield()) {
                                field_obj = new MARC.Field({
                                    tag : event.data.scope.field.tag,
                                    data : event.data.scope.field.data
                                });
                            } else {
                                var sf_clone = [];
                                for (var i in event.data.scope.field.subfields) {
                                    sf_clone.push(event.data.scope.field.subfields[i].slice());
                                }
                                field_obj = new MARC.Field({
                                    tag : event.data.scope.field.tag,
                                    ind1 : event.data.scope.field.ind1,
                                    ind2 : event.data.scope.field.ind2,
                                    subfields : sf_clone
                                });
                            }

                            event.data.scope.field.record.insertFieldsAfter(
                                event.data.scope.field,
                                field_obj
                            );

                            $scope.current_event_target = 'r' + $scope.recordId +
                                                          'f' + new_field + 'tag';

                            $scope.current_event_target_cursor_pos = 0;
                            $scope.current_event_target_cursor_pos_end = 3;
                            $scope.force_render = true;

                            $timeout(function(){$scope.$digest()}).then(setCaret);

                        } else { // jump to next field
                            if (event.data.scope.field.record.fields[event.data.scope.field.position + 1]) {
                                $timeout(function(){
                                    $scope.current_event_target_cursor_pos = 0;
                                    $scope.current_event_target_cursor_pos_end = 0;
                                    $scope.current_event_target = 'r' + $scope.recordId +
                                                                  'f' + (event.data.scope.field.position + 1) +
                                                                  'tag';
                                }).then(setCaret);
                            }
                        }

                        event_return = false;

                    } else { // Assumes only marc editor elements have IDs that can trigger this event handler.
                        $scope.current_event_target = $(event.target).attr('id');
                        if ($scope.current_event_target) {
                            $scope.current_event_target_cursor_pos =
                                event.target.selectionDirection=='backward' ?
                                    event.target.selectionStart :
                                    event.target.selectionEnd;
                        }
                    }

                    return event_return;
                };

                function setCaret() {
                    if ($scope.current_event_target) {
                        console.log("Putting caret in " + $scope.current_event_target);
                        if (!$scope.current_event_target_cursor_pos_end)
                            $scope.current_event_target_cursor_pos_end = $scope.current_event_target_cursor_pos

                        var element = $('#'+$scope.current_event_target).get(0);
                        if (element) {
                            element.focus();
                            if (element.setSelectionRange) {
                                element.setSelectionRange(
                                    $scope.current_event_target_cursor_pos,
                                    $scope.current_event_target_cursor_pos_end
                                );
                            }
                            $scope.current_event_cursor_pos_end = null;
                            $scope.current_event_target = null;
                        }
                    }
                }

                function loadRecord() {
                    return egCore.pcrud.retrieve(
                        $scope.record_type, $scope.recordId
                    ).then(function(rec) {
                        $scope.in_redo = true;
                        $scope[$scope.record_type] = rec;
                        $scope.record = new MARC.Record({ marcxml : $scope[$scope.record_type].marc() });
                        $scope.calculated_record_type = $scope.record.recordType();
                        $scope.controlfields = $scope.record.fields.filter(function(f){ return f.isControlfield() });
                        $scope.datafields = $scope.record.fields.filter(function(f){ return !f.isControlfield() });
                        $scope.save_stack_depth = $scope.record_undo_stack.length;

                        if ($scope.record_type == 'bre') {
                            $scope.bib_source = $scope[$scope.record_type].source();
                        }

                    }).then(setCaret);
                }

                $scope.$watch('record.toBreaker()', function (newVal, oldVal) {
                    if (!$scope.in_undo && !$scope.in_redo && oldVal != newVal) {
                        $scope.record_undo_stack.push({
                            breaker: oldVal,
                            target: $scope.current_event_target,
                            pos: $scope.current_event_target_cursor_pos
                        });

                        if ($scope.force_render) {
                            $scope.controlfields = $scope.record.fields.filter(function(f){ return f.isControlfield() });
                            $scope.datafields = $scope.record.fields.filter(function(f){ return !f.isControlfield() });
                            $scope.force_render = false;
                        }

                        if ($scope.record_undo_stack.length != $scope.save_stack_depth) {
                            console.log('should get a listener... does not');
                            $('body').on('beforeunload', function(){
                                return 'There is unsaved data in this record.'
                            });
                        } else {
                            $('body').off('beforeunload');
                        }
                    }

                    if ($scope.record_undo_stack.length > $scope.max_undo)
                        $scope.record_undo_stack.shift();

                    console.log('undo stack is ' + $scope.record_undo_stack.length + ' deep');
                    $scope.in_redo = false;
                    $scope.in_undo = false;
                });

                $scope.processUndo = function () {
                    if ($scope.record_undo_stack.length) {
                        $scope.in_undo = true;

                        var undo_item = $scope.record_undo_stack.pop();
                        $scope.record_redo_stack.push(undo_item);

                        $scope.record = new MARC.Record({ marcbreaker : undo_item.breaker });
                        $scope.controlfields = $scope.record.fields.filter(function(f){ return f.isControlfield() });
                        $scope.datafields = $scope.record.fields.filter(function(f){ return !f.isControlfield() });

                        $scope.current_event_target = undo_item.target;
                        $scope.current_event_target_cursor_pos = undo_item.pos;
                        console.log('Undo targeting ' + $scope.current_event_target + ' position ' + $scope.current_event_target_cursor_pos);

                        $timeout(function(){$scope.$digest()}).then(setCaret);
                        return false;
                    }

                    return true;
                };

                $scope.processRedo = function () {
                    if ($scope.record_redo_stack.length) {
                        $scope.in_redo = true;

                        var redo_item = $scope.record_redo_stack.pop();
                        $scope.record_undo_stack.push(redo_item);

                        $scope.record = new MARC.Record({ marcbreaker : redo_item.breaker });
                        $scope.controlfields = $scope.record.fields.filter(function(f){ return f.isControlfield() });
                        $scope.datafields = $scope.record.fields.filter(function(f){ return !f.isControlfield() });

                        $scope.current_event_target = redo_item.target;
                        $scope.current_event_target_cursor_pos = redo_item.pos;
                        console.log('Redo targeting ' + $scope.current_event_target + ' position ' + $scope.current_event_target_cursor_pos);

                        $timeout(function(){$scope.$digest()}).then(setCaret);
                        return false;
                    }

                    return true;
                };

                $scope.saveRecord = function () {
                    $scope.mangle_005();
                    $scope[$scope.record_type].marc($scope.record.toXmlString());
                    return egCore.pcrud.update(
                        $scope[$scope.record_type]
                    ).then(loadRecord);
                };

                $scope.seeBreaker = function () {
                    alert($scope.record.toBreaker());
                };

                $scope.$watch('recordId',
                    function(newVal, oldVal) {
                        if (newVal && newVal !== oldVal) {
                            loadRecord();
                        }
                    }
                );

                if ($scope.recordId)
                    loadRecord();

                $scope.mangle_005 = function () {
                    var now = new Date();
                    var y = now.getUTCFullYear();
                
                    var m = now.getUTCMonth() + 1;
                    if (m < 10) m = '0' + m;
                
                    var d = now.getUTCDate();
                    if (d < 10) d = '0' + d;
                
                    var H = now.getUTCHours();
                    if (H < 10) H = '0' + H;
                
                    var M = now.getUTCMinutes();
                    if (M < 10) M = '0' + M;
                
                    var S = now.getUTCSeconds();
                    if (S < 10) S = '0' + S;
                
                    var stamp = '' + y + m + d + H + M + S + '.0';
                    var f = $scope.record.field('005',true)[0];
                    if (f) {
                        f.data = stamp;
                    } else {
                        $scope.record.insertOrderedFields(
                            new MARC.Field({
                                tag : '005',
                                data: stamp
                            })
                        );
                    }
                
                }

            }
        ]          
    }
})

.directive("egMarcEditBibsource", ['$timeout',function ($timeout) {
    return {
        restrict: 'E',
        replace: true,
        template: '<span class="nullable">'+
                    '<select class="form-control" ng-model="bib_source" ng-options="s.id() as s.source() for s in bib_sources">'+
                      '<option value="">Select a Source</option>'+
                    '</select>'+
                  '</span>',
        controller: ['$scope','egCore',
            function ($scope , egCore) {

                egCore.pcrud.retrieveAll('cbs', {}, {atomic : true})
                    .then(function(list) { $scope.bib_sources = list; });

                $scope.$watch('bib_source',
                    function(newVal, oldVal) {
                        if (newVal !== oldVal) {
                            $scope.bre.source(newVal);
                        }
                    }
                );

            }
        ]
    }
}])

;
