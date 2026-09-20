using System.Collections.Generic;
using Godot;

namespace UmamusumeSimulator.ui.controls;

/// <summary>
/// Hold-to-sprint pad: one thumb steers on the joystick, the other holds this zone.
///
/// Touches are read in <c>_Input</c> with this zone's own hit test rather than in
/// <c>_GuiInput</c>, because the GUI delivers a touch only to the control under that
/// finger (<c>Viewport::_gui_input_event</c>, keyed by <c>gui.touch_focus[touch_index]</c>),
/// so a finger on the joystick is invisible here - a press on this zone could not tell
/// that another finger was already down, which is why the second finger was ignored.
/// <c>_input</c> runs before the GUI ("order is _input -> gui input -> _unhandled input"),
/// so every finger is visible here, and a touch outside this zone is passed through
/// untouched - never accepted - or the joystick would stop receiving its own.
/// </summary>
public partial class SprintTouchZone : Control
{
	private const double DoubleTapTime = 0.3;

	/// <summary>Every finger currently down anywhere on screen, by touch index.</summary>
	private readonly HashSet<int> _fingers = new();

	private double _lastTapTime;
	private bool _hasTapped;
	private bool _sprintHolding;
	private int _sprintTouchId = -1;

	public override void _Ready()
	{
		// This zone does its own hit testing, so it must stay out of GUI focus: a
		// Control that takes part in it can swallow touches meant for its neighbours.
		MouseFilter = MouseFilterEnum.Ignore;
	}

	public override void _Input(InputEvent @event)
	{
		if (@event is InputEventScreenTouch touch)
		{
			OnTouch(touch);
			return;
		}
		if (@event is InputEventScreenDrag drag && _sprintHolding && drag.Index == _sprintTouchId)
		{
			// Keep our own drag: the sprint finger is not steering anything else.
			AcceptEvent();
		}
	}

	private void OnTouch(InputEventScreenTouch touch)
	{
		if (!touch.Pressed || touch.Canceled)
		{
			_fingers.Remove(touch.Index);
			if (_sprintHolding && touch.Index == _sprintTouchId)
			{
				// A cancelled touch never sends a release, so it has to end the sprint
				// here or the player would keep sprinting with a finger off the screen.
				StopSprint();
				AcceptEvent();
			}
			return;
		}

		bool inZone = GetGlobalRect().HasPoint(touch.Position);
		bool secondFinger = _fingers.Count > 0;
		_fingers.Add(touch.Index);
		if (!inZone)
		{
			// The joystick's own touch, on its way to the GUI. Watch the finger, touch
			// nothing: accepting it here would take it away from the joystick.
			return;
		}

		double now = Time.GetTicksMsec() / 1000.0;
		bool doubleTap = _hasTapped && now - _lastTapTime < DoubleTapTime;
		if (secondFinger || doubleTap)
		{
			// One thumb on the joystick and the other on this pad is the sprint gesture
			// on its own; the double tap is what a single thumb has to do instead.
			StartSprint(touch.Index);
			AcceptEvent();
			return;
		}
		_lastTapTime = now;
		_hasTapped = true;
	}

	private void StartSprint(int touchId)
	{
		_sprintHolding = true;
		_sprintTouchId = touchId;
		_hasTapped = false;
		Input.ActionPress("sprint", 1.0f);
	}

	private void StopSprint()
	{
		Input.ActionRelease("sprint");
		_sprintHolding = false;
		_sprintTouchId = -1;
	}

	public override void _ExitTree()
	{
		if (_sprintHolding)
		{
			StopSprint();
		}
	}
}
