pragma solidity ^0.4.23;

import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";

import "../IDaoBase.sol";
import "../moneyflow/ether/WeiAbsoluteExpense.sol";


/**
 * @title WeiGenericTask 
 * @dev Basic contract for WeiTask and WeiBounty
 *
 * 4 types of tasks:
 *		PrePaid 
 *		PostPaid with known neededWei amount 
 *		PostPaid with unknown neededWei amount. Task is evaluated AFTER work is complete
 *		PostPaid donation - client pays any amount he wants AFTER work is complete
 * 
 * WeiAbsoluteExpense:
 *		has 'owner'	(i.e. "admin")
 *		has 'moneySource' (i.e. "client")
 *		has 'neededWei'
 *		has 'processFunds(uint _currentFlow)' payable function 
 *		has 'setNeededWei(uint _neededWei)' 
*/ 
contract WeiGenericTask is WeiAbsoluteExpense {
	// use DaoClient instead?
	// (it will handle upgrades)
	IDaoBase dao;
	address employee = 0x0;		// who should complete this task and report on completion
										// this will be set later
	address output = 0x0;		// where to send money (can be split later)
										// can be set later too
	string public caption = "";
	string public desc = "";
	bool public isPostpaid = false;		// prepaid/postpaid switch

	bool public isDonation = false;		// if true -> any price

	uint256 public creationTime;

	uint256 public startTime;

	uint64 public timeToCancell;

	uint64 public deadlineTime;

	enum State {
		Init,
		Cancelled,
		// only for (isPostpaid==false) tasks
		// anyone can use 'processFunds' to send money to this task
		PrePaid,

		// These are set by Employee:
		InProgress,
		CompleteButNeedsEvaluation,	// in case neededWei is 0 -> we should evaluate task first and set it
												// please call 'evaluateAndSetNeededWei'
		Complete,

		// These are set by Creator or Client:
		CanGetFunds,						// call flush to get funds
		Finished,								// funds are transferred to the output and the task is finished
		DeadlineMissed
	}
	// Use 'getCurrentState' method instead to access state outside of contract
	State state = State.Init;

	event WeiGenericTaskSetEmployee(address  _employee);
	event WeiGenericTaskSetOutput(address _output);
	event WeiGenericTaskProcessFunds(address _sender, uint _value, uint _currentFlow);
	event WeiGenericTaskStateChanged(State _state);

	modifier onlyEmployeeOrOwner() { 
		require(msg.sender == employee || msg.sender == owner); 
		_; 
	}

	modifier isCanCancell() { 
		require (block.timestamp - creationTime >= timeToCancell); 
		_; 
	}

	modifier isDeadlineMissed() { 
		require (block.timestamp - startTime >= deadlineTime); 
		_; 
	}
	

	/*
	modifier onlyAnyEmployeeOrOwner() { 
		require(dao.isEmployee(msg.sender) || msg.sender==owner); 
		_; 
	}
   */

	modifier isCanDo(bytes32 _what) {
		require(dao.isCanDoAction(msg.sender,_what)); 
		_; 
	}

	// if _neededWei==0 -> this is an 'Unknown cost' situation. use 'setNeededWei' method of WeiAbsoluteExpense
	constructor(
		IDaoBase _dao, 
		string _caption, 
		string _desc, 
		bool _isPostpaid, 
		bool _isDonation, 
		uint _neededWei, 
		uint64 _deadlineTime,
		uint64 _timeToCancell) public WeiAbsoluteExpense(_neededWei) 
	{
		require (_timeToCancell > 0);
		require (_deadlineTime > 0);
		
		// Donation should be postpaid 
		if(_isDonation) {
			require(_isPostpaid); 
		}

		if(!_isPostpaid) {
			require(_neededWei > 0);
		}

		creationTime = block.timestamp;
		dao = _dao;
		caption = _caption;
		desc = _desc;
		isPostpaid = _isPostpaid;
		isDonation = _isDonation;
		deadlineTime = _deadlineTime;
		timeToCancell = _timeToCancell * 1 hours;
	}

	// who will complete this task
	/**
	* @notice This function should be called only by owner
	* @param _employee account who will complete this task
	* @dev this function set employee account for this task
	*/
	function setEmployee(address _employee) public onlyOwner {
		emit WeiGenericTaskSetEmployee(_employee);
		employee = _employee;
	}

	// where to send money
	/**
	* @notice This function should be called only by owner
	* @param _output account who will get all funds of this task
	* @dev this function set account which will get all funds after this task will be completed
	*/
	function setOutput(address _output) public onlyOwner {
		emit WeiGenericTaskSetOutput(_output);
		output = _output;
	}

	/**
	* @return balance of this task 
	*/
	function getBalance() public view returns(uint) {
		return address(this).balance;
	}

	/**
	* @return current state of the task
	*/
	function getCurrentState() public view returns(State) {
		// for Prepaid task -> client should call processFunds method to put money into this task
		// when state is Init
		if((State.Init == state) && (neededWei != 0) && (!isPostpaid)) {
			if(neededWei == address(this).balance) {
				return State.PrePaid;
			}
		}

		// for Postpaid task -> client should call processFunds method to put money into this task
		// when state is Complete. He is confirming the task by doing that (no need to call confirmCompletion)
		if((State.Complete == state) && (neededWei != 0) && (isPostpaid)) {
			if(neededWei == address(this).balance) {
				return State.CanGetFunds;
			}
		}

		return state;
	}

	/**
	* @notice This function should be called only by owner and creation time + time to cancell should be > now
	* @dev this function cancell task and change state of the task to cancelled
	*/
	function cancell() public isCanCancell onlyOwner {
		require(getCurrentState() == State.Init || getCurrentState() == State.PrePaid);
		if(getCurrentState() == State.PrePaid) {
			// return money to 'moneySource'
			moneySource.transfer(address(this).balance);
		}
		state = State.Cancelled;
		emit WeiGenericTaskStateChanged(state);
	}

	/**
	* @notice This function should be called only by owner and creation time + deadlineMissed should be <= now
	* @dev this function return money to payeer because of deadline missed
	*/
	function returnMoney() public isDeadlineMissed onlyOwner {
		require(getCurrentState() == State.InProgress);
		if(address(this).balance > 0) {
			// return money to 'moneySource'
			moneySource.transfer(address(this).balance);
		}
		state = State.DeadlineMissed;
		emit WeiGenericTaskStateChanged(state);
	}

	/**
	* @notice This function should be called only by owner or employee
	* @dev this function change state of the task to complete
	*/
	function notifyThatCompleted() public onlyEmployeeOrOwner {
		require(getCurrentState() == State.InProgress);

		if((0!=neededWei) || (isDonation)) { // if donation or prePaid - no need in ev-ion; if postpaid with unknown payment - neededWei=0 yet

			state = State.Complete;
			emit WeiGenericTaskStateChanged(state);
		}else {
			state = State.CompleteButNeedsEvaluation;
			emit WeiGenericTaskStateChanged(state);
		}
	}

	/**
	* @notice This function should be called only by owner
	* @dev this function change state of the task to complete and sets needed wei
	*/
	function evaluateAndSetNeededWei(uint _neededWei) public onlyOwner {
		require(getCurrentState() == State.CompleteButNeedsEvaluation);
		require(0 == neededWei);

		neededWei = _neededWei;
		state = State.Complete;
		emit WeiGenericTaskStateChanged(state);
	}

	// for Prepaid tasks only! 
	// for Postpaid: call processFunds and transfer money instead!
	/**
	* @notice This function should be called only by money source (payeer)
	* @dev this function confirm completion and changes state of the task to CanGetFunds 
	*/
	function confirmCompletion() public onlyByMoneySource {
		require(getCurrentState() == State.Complete);
		require(!isPostpaid);
		require(0 != neededWei);

		state = State.CanGetFunds;
		emit WeiGenericTaskStateChanged(state);
	}

// IDestination overrides:
	// pull model
	/**
	* @dev forward funds to the output account 
	*/
	function flush() public {
		require(getCurrentState() == State.CanGetFunds);
		require(0x0 != output);

		output.transfer(address(this).balance);
		state = State.Finished;
		emit WeiGenericTaskStateChanged(state);
	}

	function flushTo(address _to) public {
		if(_to == _to) {
			revert();
		}
	}

	/**
	* @param _currentFlow index of the money flow
	* @dev should call this function when want to send funds to the task
	*/
	function processFunds(uint _currentFlow) public payable {
		emit WeiGenericTaskProcessFunds(msg.sender, msg.value, _currentFlow);
		if(isPostpaid && (0 == neededWei) && (State.Complete == state)) {
			neededWei = msg.value; // this is a donation. client can send any sum!
		}

		super.processFunds(_currentFlow);
	}

	// non-payable
	function()public {
	}
}