//! OPT(denial-fork): `zwlr_virtual_pointer_v1` server support.
//!
//! Upstream Denial implements `zwp_virtual_keyboard_v1` but not the virtual
//! pointer protocol, so any client that injects pointer input through the
//! wlroots backend (lan-mouse, wayvnc viewers, software KVMs) fails to bind
//! and its whole emulation backend goes down. This module wires Smithay's
//! protocol implementation into Denial's seat path, mirroring physical
//! pointer handling (constraints, activation, axis routing).
//!
//! Events arrive from an unprivileged Wayland client; only public session
//! clients may bind (same rule as the virtual keyboard).

use smithay::backend::input::{
    AbsolutePositionEvent, Axis, AxisSource, ButtonState, Event, InputEvent, PointerAxisEvent,
    PointerButtonEvent, PointerMotionEvent,
};
use smithay::input::pointer::{AxisFrame, ButtonEvent, MotionEvent};
use smithay::reexports::wayland_server::DisplayHandle;
use smithay::utils::{Logical, Point, SERIAL_COUNTER};
use smithay::wayland::virtual_pointer::{
    VirtualPointerBackend, VirtualPointerHandler, VirtualPointerManagerState,
};

use super::flutter_route::{
    pointer_constraint_blocks_motion, pointer_constraint_reactivation_suppressed,
};
use super::super::input_method::is_public_session_client;
use super::wayland_route::activate_surface_at;
use super::{RuntimeState, logical_axis_scroll_delta};

pub(crate) struct VirtualPointerSupport {
    _manager: VirtualPointerManagerState,
}

impl VirtualPointerSupport {
    pub(crate) fn new(display: &DisplayHandle) -> Self {
        Self {
            _manager: VirtualPointerManagerState::new::<RuntimeState, _>(display, |client| {
                is_public_session_client(client)
            }),
        }
    }
}

impl VirtualPointerHandler for RuntimeState {
    fn process_virtual_pointer_event(&mut self, event: InputEvent<VirtualPointerBackend>) {
        let state = self;
        match event {
            InputEvent::PointerMotion { event } => {
                let (position, under) = {
                    let frontend = state.frontend_mut();
                    let position =
                        frontend.clamp_pointer(frontend.pointer_location + event.delta());
                    (position, frontend.surface_under(position))
                };
                let Some(pointer) = state.frontend().seat.get_pointer() else {
                    return;
                };
                if pointer_constraint_blocks_motion(
                    &pointer,
                    &under,
                    position,
                    pointer_constraint_reactivation_suppressed(state, &pointer),
                ) {
                    pointer.frame(state);
                    return;
                }
                state.frontend_mut().pointer_location = position;
                pointer.motion(
                    state,
                    under,
                    &MotionEvent {
                        location: position,
                        serial: SERIAL_COUNTER.next_serial(),
                        time: event.time(),
                    },
                );
                pointer.frame(state);
            }
            InputEvent::PointerMotionAbsolute { event } => {
                let (position, under) = {
                    let frontend = state.frontend_mut();
                    let size = frontend.desktop_bounds.size;
                    let local = Point::<f64, Logical>::from((
                        event.x_transformed(size.w),
                        event.y_transformed(size.h),
                    ));
                    let position = frontend.clamp_pointer(local + frontend.desktop_bounds.loc.to_f64());
                    (position, frontend.surface_under(position))
                };
                let Some(pointer) = state.frontend().seat.get_pointer() else {
                    return;
                };
                if pointer_constraint_blocks_motion(
                    &pointer,
                    &under,
                    position,
                    pointer_constraint_reactivation_suppressed(state, &pointer),
                ) {
                    pointer.frame(state);
                    return;
                }
                state.frontend_mut().pointer_location = position;
                pointer.motion(
                    state,
                    under,
                    &MotionEvent {
                        location: position,
                        serial: SERIAL_COUNTER.next_serial(),
                        time: event.time(),
                    },
                );
                pointer.frame(state);
            }
            InputEvent::PointerButton { event } => {
                let serial = SERIAL_COUNTER.next_serial();
                let Some(pointer) = state.frontend().seat.get_pointer() else {
                    return;
                };
                if event.state() == ButtonState::Pressed && !pointer.is_grabbed() {
                    activate_surface_at(state, pointer.current_location(), serial);
                }
                #[cfg(feature = "flutter")]
                if super::retired_pointer_button_consumes_transition(
                    &mut state.frontend_mut().retired_pointer_buttons,
                    event.button_code(),
                    event.state(),
                ) {
                    return;
                }
                super::update_pressed_buttons(
                    &mut state.frontend_mut().wayland_pointer_buttons,
                    event.button_code(),
                    event.state(),
                );
                pointer.button(
                    state,
                    &ButtonEvent {
                        button: event.button_code(),
                        state: event.state(),
                        serial,
                        time: event.time(),
                    },
                );
                pointer.frame(state);
                state.scene_sync.mark_dirty();
            }
            InputEvent::PointerAxis { event } => {
                let source = event.source();
                let scroll_speed_factor = state.frontend().settings.touchpad().scroll_speed_factor;
                let horizontal = logical_axis_scroll_delta(
                    source,
                    event.amount(Axis::Horizontal),
                    event.amount_v120(Axis::Horizontal),
                    scroll_speed_factor,
                );
                let vertical = logical_axis_scroll_delta(
                    source,
                    event.amount(Axis::Vertical),
                    event.amount_v120(Axis::Vertical),
                    scroll_speed_factor,
                );
                let mut frame = AxisFrame::new(event.time()).source(source);
                if horizontal != 0.0 {
                    frame = frame.value(Axis::Horizontal, horizontal);
                    if let Some(v120) = event.amount_v120(Axis::Horizontal) {
                        frame = frame.v120(Axis::Horizontal, v120 as i32);
                    }
                }
                if vertical != 0.0 {
                    frame = frame.value(Axis::Vertical, vertical);
                    if let Some(v120) = event.amount_v120(Axis::Vertical) {
                        frame = frame.v120(Axis::Vertical, v120 as i32);
                    }
                }
                if source == AxisSource::Finger {
                    if event.amount(Axis::Horizontal) == Some(0.0) {
                        frame = frame.stop(Axis::Horizontal);
                    }
                    if event.amount(Axis::Vertical) == Some(0.0) {
                        frame = frame.stop(Axis::Vertical);
                    }
                }
                let Some(pointer) = state.frontend().seat.get_pointer() else {
                    return;
                };
                pointer.axis(state, frame);
                pointer.frame(state);
            }
            _ => {}
        }
    }
}
