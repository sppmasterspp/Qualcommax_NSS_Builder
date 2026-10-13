'use strict';

'require view';
'require form';
'require rpc';
'require poll';
'require dom';
'require ui';

const callStatus = rpc.declare({
	object: 'luci.fan-monitor',
	method: 'status',
	expect: { '': {} }
});

const callAction = rpc.declare({
	object: 'luci.fan-monitor',
	method: 'action',
	params: [ 'action' ],
	expect: { '': {} }
});

function formatTemperature(value) {
	return (typeof(value) === 'number') ? '%.1f °C'.format(value / 1000) : _('N/A');
}

function formatNumber(value, suffix) {
	return (typeof(value) === 'number') ? '%s%s'.format(value, suffix || '') : _('N/A');
}

function validState(state) {
	return (typeof(state) === 'number' && state >= 0 && state <= 3) ? state : null;
}

function fanStateName(state) {
	switch (state) {
	case 0: return _('Off');
	case 1: return _('Low');
	case 2: return _('Medium');
	case 3: return _('Maximum');
	default: return _('Unknown');
	}
}

function stateStyle(state, topTrigger) {
	let style = '';

	switch (state) {
	case 1:
		style = 'background:#5cb85c;color:#fff;border-color:#4cae4c;';
		break;
	case 2:
		style = 'background:#f0ad4e;color:#1b1b1b;border-color:#eea236;';
		break;
	case 3:
		style = 'background:#d9534f;color:#fff;border-color:#d43f3a;';
		break;
	default:
		style = '';
	}

	if (topTrigger && state > 0)
		style += 'box-shadow:0 0 0 3px rgba(0,0,0,.28),0 1px 3px rgba(0,0,0,.18);';

	return style;
}

function statusCard(title, value, detail, cssClass, extraStyle) {
	return E('div', {
		'class': 'cbi-section ' + (cssClass || ''),
		'style': 'margin:0;padding:1em;min-width:150px;transition:background-color .25s,border-color .25s,box-shadow .25s;' + (extraStyle || '')
	}, [
		E('div', { 'style': 'font-size:.85em;opacity:.8;margin-bottom:.35em;' }, title),
		E('div', { 'style': 'font-size:1.55em;font-weight:600;line-height:1.2;' }, value),
		detail ? E('div', { 'style': 'font-size:.85em;opacity:.85;margin-top:.35em;line-height:1.35;' }, detail) : ''
	]);
}

function requestThreshold(thresholds, state) {
	if (!thresholds)
		return null;

	switch (state) {
	case 1: return thresholds.low;
	case 2: return thresholds.medium;
	case 3: return thresholds.maximum;
	default: return thresholds.low;
	}
}

function sensorDetail(detected, state, thresholds, topTrigger, failsafe) {
	let details = [];
	const threshold = requestThreshold(thresholds, state);

	if (!detected)
		details.push(_('Sensor not detected'));

	if (failsafe) {
		details.push(_('Fail-safe requests Maximum'));
	}
	else if (state === null) {
		details.push(_('Cooling request unavailable'));
	}
	else if (state === 0) {
		if (typeof(threshold) === 'number')
			details.push(_('Below Low threshold %s').format(formatTemperature(threshold)));
		else
			details.push(_('No fan request'));
	}
	else {
		if (typeof(threshold) === 'number')
			details.push(_('Requests %s at ≥ %s').format(fanStateName(state), formatTemperature(threshold)));
		else
			details.push(_('Requests %s').format(fanStateName(state)));
	}

	if (topTrigger && state > 0)
		details.push(_('Top fan trigger'));

	return details.join(' • ');
}

function sensorStatusCard(title, temperature, detected, state, thresholds, desiredState, failsafe, extraDetail) {
	const normalizedState = validState(state);
	const topTrigger = normalizedState !== null && normalizedState > 0 && normalizedState === desiredState;
	let detail = sensorDetail(detected, normalizedState, thresholds, topTrigger, failsafe);

	if (extraDetail)
		detail = extraDetail + (detail ? ' • ' + detail : '');

	return statusCard(title, formatTemperature(temperature), detail, '', stateStyle(normalizedState, topTrigger));
}

function legendItem(background, color, text, outline) {
	return E('span', {
		'style': 'display:inline-flex;align-items:center;gap:.4em;margin-right:1.1em;margin-bottom:.35em;'
	}, [
		E('span', {
			'style': 'display:inline-block;width:1.05em;height:1.05em;border-radius:.2em;background:' + background + ';border:1px solid ' + (outline || background) + ';'
		}),
		E('span', { 'style': 'color:' + (color || 'inherit') + ';' }, text)
	]);
}

function identityValue(value) {
	return (typeof(value) === 'string' && value && value !== 'Unknown') ? value : _('Unknown');
}

function detailRow(label, value) {
	return E('div', { 'style': 'display:grid;grid-template-columns:minmax(150px,220px) 1fr;gap:.75em;padding:.25em 0;' }, [
		E('strong', {}, label),
		E('span', { 'style': 'overflow-wrap:anywhere;' }, identityValue(value))
	]);
}

return view.extend({
	statusContainer: null,

	load: function() {
		return callStatus();
	},

	handleAction: function(action, ev) {
		if (ev && ev.currentTarget)
			ev.currentTarget.disabled = true;

		return callAction(action).then(L.bind(function(result) {
			this.updateStatus(result || {});
			if (result && result.code === 0)
				ui.addNotification(null, E('p', {}, _('Command completed successfully.')), 'info');
			else
				ui.addNotification(_('Fan Control'), E('p', {}, _('The command failed. Check the system log.')), 'danger');
		}, this)).catch(function(err) {
			ui.addNotification(_('Fan Control'), E('p', {}, err.message), 'danger');
		});
	},

	buildStatus: function(data) {
		data = data || {};
		const fan = data.fan || {};
		const temp = data.temperatures || {};
		const thermal = data.thermal || {};
		const sensors = data.sensors || {};
		const requests = data.requests || {};
		const thresholds = data.thresholds || {};
		const failsafe = data.failsafe || {};
		const control = data.control || {};
		const hardware = data.hardware || {};
		const aqr = data.aqr || {};
		const running = data.running === true;
		const autostart = data.autostart === true;
		const thermalProtected = thermal.protected === true;
		const serviceText = running ? _('Running') : _('Stopped');
		const serviceDetail = running && typeof(data.pid) === 'number' ? 'PID %d'.format(data.pid) : '';
		const desiredState = validState(requests.desired);
		let fanDetail = _('PWM: %s').format(formatNumber(fan.pwm, ''));
		const aqrModel = identityValue(aqr.model);
		let aqrTitle;
		if (/^AQR[0-9]/.test(aqrModel))
			aqrTitle = _('Aquantia %s 10G PHY').format(aqrModel);
		else if (aqrModel !== _('Unknown'))
			aqrTitle = _('%s 10G PHY').format(aqrModel);
		else
			aqrTitle = _('Aquantia/Marvell AQ-family 10G PHY');
		let aqrIdentity = [];
		if (aqr.phy_id && aqr.phy_id !== 'Unknown')
			aqrIdentity.push(_('PHY ID %s').format(aqr.phy_id));
		if (aqr.mdio_address && aqr.mdio_address !== 'Unknown')
			aqrIdentity.push(_('MDIO %s').format(aqr.mdio_address));
		if (aqr.netdev && aqr.netdev !== 'Unknown')
			aqrIdentity.push(aqr.netdev);
		const revisionDetail = [ hardware.pcb_revision, hardware.confidence ? _('confidence: %s').format(hardware.confidence) : null ]
			.filter(function(v) { return v && v !== 'Unknown'; }).join(' • ');

		if (desiredState !== null)
			fanDetail += ' • ' + _('Sensors request: %s').format(fanStateName(desiredState));

		if (typeof(control.pending_state) === 'number' && typeof(control.pending_count) === 'number') {
			fanDetail += ' • ' + _('Downshift to %s: %d/%d').format(
				fanStateName(control.pending_state), control.pending_count, control.downshift_intervals || 0);
		}

		return E('div', {}, [
			E('h2', {}, _('Fan Control')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Live monitoring and configuration for the RT-AX89X GPIO fan controller. The AQR-family PHY and router revision are detected at runtime. Values refresh every five seconds.')),
			E('div', {
				'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:.75em;margin:1em 0;'
			}, [
				statusCard(_('Service'), serviceText, serviceDetail,
					running ? 'alert-message success' : 'alert-message warning'),
				statusCard(_('Fan speed'), formatNumber(fan.input, ' RPM'),
					_('Target: %s RPM').format(formatNumber(fan.target, ''))),
				statusCard(_('Fan state'), fanStateName(fan.state), fanDetail),
				sensorStatusCard(_('CPU maximum'), temp.cpu, (sensors.cpu_count || 0) > 0,
					requests.cpu, thresholds.cpu, desiredState, failsafe.cpu === true,
					_('%d CPU/cluster sensors').format(sensors.cpu_count || 0)),
				sensorStatusCard(aqrTitle, temp.aqr113c, sensors.aqr_found === true,
					requests.aqr113c, thresholds.aqr113c, desiredState, failsafe.aqr113c === true,
					aqrIdentity.join(' • ')),
				sensorStatusCard(_('Wi-Fi phy0'), temp.wifi0, sensors.wifi0_found === true,
					requests.wifi0, thresholds.wifi, desiredState, failsafe.wifi0 === true),
				sensorStatusCard(_('Wi-Fi phy1'), temp.wifi1, sensors.wifi1_found === true,
					requests.wifi1, thresholds.wifi, desiredState, failsafe.wifi1 === true),
				statusCard(_('Router hardware'), identityValue(hardware.revision), revisionDetail),
				statusCard(_('Kernel thermal protection'),
					thermalProtected ? _('Enabled') : _('Check required'),
					_('%d of %d CPU zones enabled').format(thermal.enabled || 0, thermal.total || 0),
					thermalProtected ? 'alert-message success' : 'alert-message warning'),
				statusCard(_('Start at boot'), autostart ? _('Enabled') : _('Disabled'), '')
			]),
			E('div', {
				'class': 'cbi-section',
				'style': 'padding:.8em 1em;margin:.75em 0;'
			}, [
				E('div', { 'style': 'font-weight:600;margin-bottom:.45em;' }, _('Temperature card colors')),
				E('div', {}, [
					legendItem('transparent', 'inherit', _('No fan request'), '#999'),
					legendItem('#5cb85c', 'inherit', _('Low-speed request'), '#4cae4c'),
					legendItem('#f0ad4e', 'inherit', _('Medium-speed request'), '#eea236'),
					legendItem('#d9534f', 'inherit', _('Maximum-speed request'), '#d43f3a')
				]),
				E('div', { 'style': 'font-size:.9em;opacity:.8;margin-top:.25em;' },
					_('Each sensor card shows its own cooling request. A dark outline marks the sensor or sensors making the highest current request, so several outlined cards indicate simultaneous triggers.'))
			]),
			E('div', { 'class': 'cbi-section', 'style': 'padding:.8em 1em;margin:.75em 0;' }, [
				E('h3', {}, _('Detected hardware')),
				detailRow(_('Router model'), hardware.model),
				detailRow(_('Hardware revision'), hardware.revision),
				detailRow(_('PCB range'), hardware.pcb_revision),
				detailRow(_('Inference confidence'), hardware.confidence),
				detailRow(_('Revision basis'), hardware.basis),
				detailRow(_('AQR model'), aqr.model),
				detailRow(_('Kernel PHY driver'), aqr.driver),
				detailRow(_('PHY ID'), aqr.phy_id),
				detailRow(_('MDIO address'), aqr.mdio_address),
				detailRow(_('Attached interface'), aqr.netdev),
				detailRow(_('Device-tree path'), aqr.of_path),
				detailRow(_('Temperature input'), aqr.temp_input),
				detailRow(_('Detection method'), aqr.detection_method),
				(aqr.identity_warning ? E('div', { 'class': 'alert-message warning', 'style': 'margin-top:.5em;' }, aqr.identity_warning) : ''),
				E('div', { 'style': 'font-size:.9em;opacity:.8;margin-top:.5em;' },
					_('The B1/B2 value is an inference from the active PHY model and MDIO layout, not a factory serial-number field.'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service control')),
				E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left;' }, [
					E('button', {
						'class': 'cbi-button cbi-button-positive',
						'disabled': running ? true : null,
						'click': ui.createHandlerFn(this, 'handleAction', 'start')
					}, _('Start')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'disabled': running ? null : true,
						'click': ui.createHandlerFn(this, 'handleAction', 'stop')
					}, _('Stop')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'disabled': running ? null : true,
						'click': ui.createHandlerFn(this, 'handleAction', 'restart')
					}, _('Restart')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'disabled': autostart ? true : null,
						'click': ui.createHandlerFn(this, 'handleAction', 'enable')
					}, _('Enable at boot')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-reset',
						'disabled': autostart ? null : true,
						'click': ui.createHandlerFn(this, 'handleAction', 'disable')
					}, _('Disable at boot'))
				])
			])
		]);
	},

	updateStatus: function(data) {
		if (this.statusContainer)
			dom.content(this.statusContainer, this.buildStatus(data));
	},

	render: function(status) {
		let m, s, o;

		this.statusContainer = E('div', { 'id': 'fan-monitor-live-status' }, this.buildStatus(status));

		m = new form.Map('fan_monitor', _('Fan settings'),
			_('Temperatures are configured in whole degrees Celsius. Increasing fan speed is immediate; reducing it is delayed to avoid rapid switching.'));

		s = m.section(form.NamedSection, 'main', 'fan_monitor', _('Configuration'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('general', _('General'));
		s.tab('rpm', _('Fan speeds'));
		s.tab('cpu', _('CPU thresholds'));
		s.tab('aqr', _('Aquantia PHY thresholds'));
		s.tab('wifi', _('Wi-Fi thresholds'));

		o = s.taboption('general', form.Value, 'interval_sec', _('Sampling interval'));
		o.datatype = 'range(1,300)';
		o.default = '15';
		o.rmempty = false;
		o.description = _('Seconds between temperature samples.');

		o = s.taboption('general', form.Value, 'downshift_intervals', _('Downshift delay'));
		o.datatype = 'range(1,60)';
		o.default = '4';
		o.rmempty = false;
		o.description = _('Number of consecutive samples required before reducing fan speed.');

		o = s.taboption('general', form.Value, 'sensor_fail_limit', _('Sensor failure limit'));
		o.datatype = 'range(1,20)';
		o.default = '3';
		o.rmempty = false;
		o.description = _('After this many invalid samples the fan is forced to maximum speed.');

		o = s.taboption('general', form.Flag, 'enable_thermal_zones', _('Keep kernel thermal protection enabled'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Recommended. Keeps CPU fan trip points and CPU frequency throttling active as a separate safety layer.');

		o = s.taboption('general', form.Flag, 'debug', _('Debug logging'));
		o.default = '0';
		o.rmempty = false;

		function rpmOption(name, title, value) {
			const opt = s.taboption('rpm', form.Value, name, title);
			opt.datatype = 'range(0,10000)';
			opt.default = value;
			opt.rmempty = false;
			return opt;
		}

		rpmOption('off_rpm', _('Off target'), '0');
		rpmOption('low_rpm', _('Low target'), '1600');
		rpmOption('mid_rpm', _('Medium target'), '1850');
		rpmOption('max_rpm', _('Maximum target'), '2100');

		function threshold(tab, name, title, value, description) {
			const opt = s.taboption(tab, form.Value, name, title);
			opt.datatype = 'range(0,125)';
			opt.default = value;
			opt.rmempty = false;
			opt.description = description || '';
			return opt;
		}

		threshold('cpu', 'cpu_low_up', _('Low speed: increase at'), '62');
		threshold('cpu', 'cpu_mid_up', _('Medium speed: increase at'), '66');
		threshold('cpu', 'cpu_max_up', _('Maximum speed: increase at'), '70');
		threshold('cpu', 'cpu_low_down', _('Off: reduce below'), '59');
		threshold('cpu', 'cpu_mid_down', _('Low speed: reduce below'), '63');
		threshold('cpu', 'cpu_max_down', _('Medium speed: reduce below'), '67');

		threshold('aqr', 'aqr_low_up', _('Low speed: increase at'), '65');
		threshold('aqr', 'aqr_mid_up', _('Medium speed: increase at'), '74');
		threshold('aqr', 'aqr_max_up', _('Maximum speed: increase at'), '80');
		threshold('aqr', 'aqr_low_down', _('Off: reduce below'), '62');
		threshold('aqr', 'aqr_mid_down', _('Low speed: reduce below'), '72');
		threshold('aqr', 'aqr_max_down', _('Medium speed: reduce below'), '78');

		threshold('wifi', 'wifi_low_up', _('Low speed: increase at'), '68');
		threshold('wifi', 'wifi_mid_up', _('Medium speed: increase at'), '73');
		threshold('wifi', 'wifi_max_up', _('Maximum speed: increase at'), '78');
		threshold('wifi', 'wifi_low_down', _('Off: reduce below'), '65');
		threshold('wifi', 'wifi_mid_down', _('Low speed: reduce below'), '70');
		threshold('wifi', 'wifi_max_down', _('Medium speed: reduce below'), '75');

		poll.add(L.bind(function() {
			return callStatus().then(L.bind(this.updateStatus, this));
		}, this), 5);

		return m.render().then(L.bind(function(mapNode) {
			return E('div', {}, [ this.statusContainer, mapNode ]);
		}, this));
	}
});
