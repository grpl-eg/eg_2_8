dojo.require('dijit.form.Button');
dojo.require('openils.widget.ProgressDialog');
dojo.requireLocalization("openils.acq", "acq");
var localeStrings = dojo.i18n.getLocalization("openils.acq", "acq");

function load() {
    progressDialog.show(true);
    fieldmapper.standardRequest(
        ["open-ils.acq", "open-ils.acq.lineitem.format"], {
            "params": [openils.User.authtoken, liId, "html"],
            "async": true,
            "oncomplete": function(r) {
                r = openils.Util.readResponse(r);
                progressDialog.hide();
                var d = dojo.byId("acq-worksheet-contents");
                if (r.template_output())
                    d.innerHTML = r.template_output().data();
                else if (r.error_output())
                    d.innerHTML = r.error_output().data();
                else
                    d.innerHTML = localeStrings.LI_FORMAT_ERROR;
            }
        }
    );
}

function print_node(node_id) {
    var iframe = document.createElement("iframe");
    var source_node = dojo.byId(node_id);
    source_node.parentNode.appendChild(iframe);

    var iwin = iframe.contentWindow;

    iwin.document.close();

    iwin.document.body.innerHTML = source_node.innerHTML;
    iframe.focus();

    try { iframe.print(); } catch (e) { iwin.print(); }
    setTimeout(function() { iframe.style.display = "none"; }, 3500);
}


openils.Util.addOnLoad(load);
