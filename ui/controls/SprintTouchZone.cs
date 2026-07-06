using Godot;

namespace UmamusumeSimulator;

public partial class SprintTouchZone : Control
{
	private double _lastTapTime;
	private bool _sprintHolding;
	private int _sprintTouchId = -1;
	private const double DoubleTapTime = 0.3;

	public override void _Ready()
	{
		MouseFilter = MouseFilterEnum.Pass;
	}

	public override void _GuiInput(InputEvent @event)
	{
		if (@event is InputEventScreenTouch touch)
		{
			if (touch.Pressed)
			{
				double now = Time.GetTicksMsec() / 1000.0;
				if (now - _lastTapTime < DoubleTapTime && _lastTapTime > 0.0)
				{
					_sprintHolding = true;
					_sprintTouchId = touch.Index;
					Input.ActionPress("sprint", 1.0f);
					_lastTapTime = 0.0;
					AcceptEvent();
				}
				else
				{
					_lastTapTime = now;
				}
			}
			else
			{
				if (_sprintHolding && touch.Index == _sprintTouchId)
				{
					Input.ActionRelease("sprint");
					_sprintHolding = false;
					_sprintTouchId = -1;
					AcceptEvent();
				}
			}
		}
		else if (@event is InputEventScreenDrag drag)
		{
			if (_sprintHolding && drag.Index == _sprintTouchId)
			{
				AcceptEvent();
			}
		}
	}

	public override void _ExitTree()
	{
		if (_sprintHolding)
		{
			Input.ActionRelease("sprint");
			_sprintHolding = false;
		}
	}
}
