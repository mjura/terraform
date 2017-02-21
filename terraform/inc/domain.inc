<% if exists? "floating_ip" %>

    <% if provider == "openstack" %>

        resource "openstack_compute_floatingip_v2" "fip_<%= name %>" {
            <% if exists? "count" %>
                count            = <%= count %>
            <% end %>
            pool = "floating"
        }

        output "fip_<%= name %>" {
            <% if exists? "count" %>
                value = "${join(",",openstack_compute_floatingip_v2.fip_<%= name %>.*.address)}"
            <% else %>
                value = "${openstack_compute_floatingip_v2.fip_<%= name %>.address}"
            <% end %>
        }

    <% elsif provider == "libvirt" %>

        output "ip_<%= name %>" {
            <% if exists? "count" %>
                value = "${join(",", libvirt_domain.<%= name %>.*.network_interface.0.addresses.0)}"
            <% else %>
                value = "${libvirt_domain.<%= name %>.network_interface.0.addresses.0}"
            <% end %>
        }

    <% end %>

<% end %>

resource "<%= domain_type %>" "<%= name %>" {

    <% if !exists? "hostname" %>
        <% set("hostname", name) %>
    <% end %>

    <% if exists? "count" %>
        <% full_name     = "#{cluster_prefix}_#{name}${count.index}" %>
        <% full_hostname = fqdn("#{hostname}${count.index}") %>

        count            = <%= count %>
        name             = "<%= full_name %>"
    <% else %>
        <% full_name     = "#{cluster_prefix}_#{name}" %>
        <% full_hostname = fqdn(hostname) %>

        name             = "<%= full_name %>"
    <% end %>

    <% if exists? "depends_on" %>
        depends_on = <%= depends_on %>
    <% end %>

    <%= render "disk.inc", volume_id: name %>
    <%= render "net_iface.inc",
        hostname: full_hostname,
        count: count,
        floating_ip: floating_ip,
        bastion: bastion %>

    <% if provider == "libvirt" %>

        <% if exists? "#{name}_memory" %>
            memory = <%= eval("#{name}_memory") %>
        <% elsif exists?("memory") %>
            memory = <%= memory %>
        <% end %>

        <% if enabled?("is_uefi_image") && exists?("firmware") %>
            firmware = "<%= firmware %>"
        <% end %>

    <% elsif provider == "openstack" %>

        <% if exists? "#{name}_flavor" %>
            flavor_name = <%= eval("#{name}_flavor") %>
        <% elsif exists? "flavor_name" %>
            flavor_name  = "<%= flavor_name %>"
        <% else %>
            flavor_name  = "m1.small"
        <% end %>

        key_pair         = "<%= cluster_prefix %>_keypair"

        security_groups = [
            "default",
            "${openstack_compute_secgroup_v2.terraform.name}",
        ]
    <% end %>

    provisioner "remote-exec" {
        inline = [
            "mkdir -p /root/.ssh",
        ]
    }

    provisioner "file" {
        source      = "<%= ssh_key %>"
        destination = "/root/.ssh/id_rsa"
    }

    provisioner "file" {
        source      = "<%= ssh_key %>.pub"
        destination = "/root/.ssh/id_rsa.pub"
    }

    <% if enabled? "is_dashboard" %>

        provisioner "file" {
            source      = "<%= tf_dir %>/provision/dashboard/provision-dashboard.sh"
            destination = "/tmp/provision-dashboard.sh"
        }

        provisioner "file" {
            source      = "<%= tf_dir %>/provision/dashboard/salt"
            destination = "/tmp"
        }

        provisioner "file" {
            source      = "<%= salt_dir %>/salt"
            destination = "/srv"
        }

        provisioner "file" {
            source      = "<%= salt_dir %>/pillar"
            destination = "/srv"
        }

        provisioner "remote-exec" {
            inline = [
                "[ -d /etc/kubernetes/manifests ] || mkdir -p /etc/kubernetes/manifests",
            ]
        }

        provisioner "file" {
            source      = "<%= tf_dir %>/provision/dashboard/manifests/"
            destination = "/etc/kubernetes/manifests"
        }

        provisioner "remote-exec" {
            inline = [
                <%# depending on some variables, we set some flags in the Salt master %>
                <%# that will be translated to data in the Salt pillar... %>

                <% prov_args  = "--dashboard #{dashboard_ref}" %>
                <% if exists? "infra" %>
                    <% prov_args  = "--infra #{infra}" %>
                <% end %>
                <% if enabled? "e2e" %>
                    <% prov_args  = "#{prov_args} --e2e" %>
                <% end %>
                <% if exists? "docker_reg_mirror" %>
                    <% prov_args  = "#{prov_args} --docker-reg-mirror #{docker_reg_mirror}" %>
                <% end %>
                "bash /tmp/provision-dashboard.sh <%= prov_args %>",
            ]
        }

    <% else %>

        provisioner "file" {
            source      = "<%= tf_dir %>/provision/minion/provision-salt-minion.sh"
            destination = "/tmp/provision-salt-minion.sh"
        }

        provisioner "file" {
            source      = "<%= tf_dir %>/provision/minion/salt"
            destination = "/tmp"
        }

        <% if !enabled?("skip_role_assignments") && !enabled?("skip_dashboard") %>
            provisioner "file" {
                source      = "<%= tf_dir %>/provision/minion/salt/all-grains/<%= hostname %>"
                destination = "/tmp/salt/grains"
            }
        <% end %>

        provisioner "remote-exec" {
            inline = [
                <% prov_args  = "--dashboard-host #{dashboard} " %>
                <% prov_args += "--skip-role-assignments " if enabled?("skip_role_assignments") || enabled?("skip_dashboard") %>
                "bash /tmp/provision-salt-minion.sh <%= prov_args %>",
            ]
        }

    <% end %>

    <%= render "cloudinit.inc", name: name, count: count %>
}
