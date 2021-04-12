pragma solidity 0.6.12;

import '../libs/SafeMath.sol';
import '../libs/IBEP20.sol';
import '../libs/SafeBEP20.sol';
import '../token/SlimeTokenV2.sol';
import '../libs/ReentrancyGuard.sol';

//  referral
interface SlimeFriends {
    function setSlimeFriend(address farmer, address referrer) external;
    function getSlimeFriend(address farmer) external view returns (address);
}

//  Non fee users that use previus buggy chef
interface BuggyOldMasterChef {
   function userInfo(uint256 _pid, address user) external view returns(uint256,uint256);
}

 contract IRewardDistributionRecipient is Ownable {
    address public rewardReferral;
    address public rewardVote;


    function setRewardReferral(address _rewardReferral) external onlyOwner {
        rewardReferral = _rewardReferral;
    }
}
/**
 * @dev Implementation of the {IBEP20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {BEP20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-BEP20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of BEP20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IBEP20-approve}.
 */

// MasterChef is the master of slime. He can make slime and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once slime is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract SlimeMasterChefV2   is IRewardDistributionRecipient , ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of slimes
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accslimePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accslimePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. slimes to distribute per block.
        uint256 lastRewardBlock;  // Last block number that slimes distribution occurs.
        uint256 accslimePerShare; // Accumulated slimes per share, times 1e12. See below.
        uint256 fee;
    }


    SlimeTokenV2 public st;

    // Dev address.aqui va el dinero para la falopa del dev
    address public devaddr;

    address public divPoolAddress;
    // slime tokens created per block.
    uint256 public slimesPerBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when This   mining starts.
    uint256 public startBlock;

    uint256 public constant BONUS_MULTIPLIER = 1;

    uint256[5] public fees;

    uint256 public constant MAX_FEE_ALLOWED = 100; //10%

    uint256 public stakepoolId = 0;

    bool public enableWhitelistFee = true;

    address public buggyOldChef = address(0x2Ee13A83aca66A218d2e4C6A5b3FCC299aB1e5e6);

    mapping(address => bool ) public trustedAddress;


    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event MassHarvestStake(uint256[] poolsId,bool withStake,uint256 extraStake);
    event InternalDeposit(address indexed user, uint256 indexed pid, uint256 amount);
    event DepositFor(address indexed user,address indexed userTo, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ReferralPaid(address indexed user,address indexed userTo, uint256 reward);
    event Burned(uint256 reward);

    event UpdateDevAddress(address  previousAddress,address  newAddress);
    event UpdateDivPoolAddress(address  previousAddress,address  newAddress);
    event UpdateSlimiesPerBlock(uint256  previousRate,uint256  newRate);
    event UpdateFees(uint256 indexed feeID,uint256 amount);
    event UpdateStakePool(uint256 indexed previousId,uint256 newId);
    event UpdateTrustedAddress(address indexed _address,bool state);

    constructor(
        SlimeTokenV2 _st,

        address _devaddr,
        address _divPoolAddress,
        uint256 _slimesPerBlock,
        uint256 _startBlock
    ) public {
        st = _st;

        devaddr = _devaddr;
        divPoolAddress = _divPoolAddress;
        slimesPerBlock = _slimesPerBlock;
        startBlock = _startBlock;

        totalAllocPoint = 0;

        fees[0] = 15;  // referral Fee (Slime) = 1.5%
        fees[1] = 70;  // treasury Fee (Slime) = 7%
        fees[2] = 30;  // dev Fee (Slime) = 3%
        fees[3] = 30;  // treasury deposit Fee  = 3%
        fees[4] = 10; // dev deposit Fee  = 1%
    }

    modifier validatePoolByPid(uint256 _pid) {
    require (_pid < poolLength(),"Pool does not exist");
    _;
    }

    modifier nonDuplicated(IBEP20 token) {
        require(tokenList[token] == false, "nonDuplicated: duplicated");
        _;
    }


    mapping(IBEP20 => bool) public tokenList;


    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, bool _withUpdate,
     uint256 __lastRewardBlock,uint256 __fee) external onlyOwner nonDuplicated(_lpToken) {

          // if _fee == 100 then 100% of dev and treasury fee is applied, if _fee = 50 then 50% discount, if 0 , no fee
        require(__fee<=100);

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = __lastRewardBlock == 0 ? block.number > startBlock ? block.number : startBlock : __lastRewardBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        tokenList[_lpToken] = true;

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accslimePerShare: 0,
            fee:__fee
        }));

    }

    // Update the given pool's SLIME allocation point. Can only be called by the owner. if update lastrewardblock, need update pools
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate,
     uint256 __lastRewardBloc,uint256 __fee) external onlyOwner validatePoolByPid(_pid) {
        // if _fee == 100 then 100% of dev and treasury fee is applied, if _fee = 50 then 50% discount, if 0 , no fee
         require(__fee<=100);

         if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        if(__lastRewardBloc>0)
            poolInfo[_pid].lastRewardBlock = __lastRewardBloc;

            poolInfo[_pid].fee = __fee;
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    /**
     * Check if address used previus masterchef pool to avoid pay fee again
     */
    function isWhiteListed (uint256 _pid,address _address) public view returns (bool) {
        if(buggyOldChef==address(0) || enableWhitelistFee==false)
            return false;

       (uint256 amount,uint256 rewardDebt) = BuggyOldMasterChef(buggyOldChef).userInfo(_pid, _address);
        if(rewardDebt>0){
            return true;
        }
        return false;
    }

    // View function to see pending tokens on frontend.
    function pendingReward(uint256 _pid, address _user) validatePoolByPid(_pid)  external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accslimePerShare = pool.accslimePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 slimeReward = multiplier.mul(slimesPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

            accslimePerShare = accslimePerShare.add(slimeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accslimePerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }


    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 slimeReward = multiplier.mul(slimesPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

         st.mint(address(this), slimeReward);
         //treasury and dev
         st.mint(divPoolAddress, slimeReward.mul(fees[1]).div(1000));
         st.mint(devaddr, slimeReward.mul(fees[2]).div(1000));

        pool.accslimePerShare = pool.accslimePerShare.add(slimeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

     // Update reward variables of the given pool to be up-to-date. Internal function used for massHarvestStake for gas optimization
     function internalUpdatePool(uint256 _pid) internal returns(uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return 0;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return 0;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 slimeReward = multiplier.mul(slimesPerBlock).mul(pool.allocPoint).div(totalAllocPoint);


        pool.accslimePerShare = pool.accslimePerShare.add(slimeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
        return slimeReward;
    }
    /**
    ** Harvest all pools where user has pending balance at same time!  Be careful of gas spending!
    ** ids[] list of pools id to harvest, [0] to harvest all
    ** stake if true all pending balance is staked To Stake Pool  (stakepoolId)
    ** extraStake if >0, desired user balance will be added to pending for stake too
    **/
    function massHarvestStake(uint256[] memory ids,bool stake,uint256 extraStake) external nonReentrant {
        bool zeroLenght = ids.length==0;
        uint256 idxlength = ids.length;

        //if empty check all
        if(zeroLenght)
              idxlength = poolInfo.length;

        uint256 totalPending = 0;
        uint256 accumulatedSlimeReward = 0;

          for (uint256 i = 0; i < idxlength;  i++) {
                   uint256 pid = zeroLenght ? i :  ids[i];
                   require (pid < poolLength(),"Pool does not exist");
                    // updated updatePool to gas optimization
                    accumulatedSlimeReward = accumulatedSlimeReward.add(internalUpdatePool(pid));

                   PoolInfo storage pool = poolInfo[pid];
                   UserInfo storage user = userInfo[pid][msg.sender];
                   uint256 pending = user.amount.mul(pool.accslimePerShare).div(1e12).sub(user.rewardDebt);
                   if(pending > 0) {
                       totalPending = totalPending.add(pending);
                    }
                   user.rewardDebt = user.amount.mul(pool.accslimePerShare).div(1e12);
            }

            st.mint(address(this), accumulatedSlimeReward);
            st.mint(divPoolAddress, accumulatedSlimeReward.mul(fees[1]).div(1000));
            st.mint(devaddr, accumulatedSlimeReward.mul(fees[2]).div(1000));

            if(totalPending>0)
            {
                payRefFees(totalPending);
                uint256 totalHarvested = deflacionaryHarvest(st,msg.sender,totalPending);
                emit RewardPaid(msg.sender, totalPending);

                if( stake && stakepoolId!=0)
                {
                     if(extraStake>0)
                      totalHarvested = totalHarvested.add(extraStake);

                     internalDeposit(stakepoolId, totalHarvested);
                }
            }
        emit MassHarvestStake(ids,stake,extraStake);
    }

    /**
     * Avoid nonReentrant only for massHarvestStake autoStake method, removed updatePool && pending payment
     *
     */
    function internalDeposit(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];


        if (_amount > 0) {
            //check for deflacionary assets
            _amount = deflacionaryDeposit(pool.lpToken,_amount);

           if(pool.fee > 0){

                uint256  treasuryfee = _amount.mul(pool.fee).mul(fees[3]).div(100000);
                uint256 devfee = _amount.mul(pool.fee).mul(fees[4]).div(100000);

                 if(treasuryfee>0)
                    pool.lpToken.safeTransfer(divPoolAddress, treasuryfee);
                if(devfee>0)
                    pool.lpToken.safeTransfer(devaddr, devfee);

                user.amount = user.amount.add(_amount).sub(treasuryfee).sub(devfee);
            }else{
                user.amount = user.amount.add(_amount);
            }

        }
        user.rewardDebt = user.amount.mul(pool.accslimePerShare).div(1e12);

        emit InternalDeposit(msg.sender, _pid, _amount);
    }

    /**
    * Allow 3* part aplication do deposit for a user just when user (tx.origin) use them and "tx.origin" must be equals "to" for security (unauthorized actions)  , deposit amount is requested to msg.sender
     */
    function depositFor(uint256 _pid, uint256 _amount,address to) external nonReentrant validatePoolByPid(_pid) {
        require(tx.origin==to || trustedAddress[msg.sender]);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][to];

        uint256 pending = 0;

        updatePool(_pid);

        if (user.amount > 0) {
              pending = user.amount.mul(pool.accslimePerShare).div(1e12).sub(user.rewardDebt);

               if(pending > 0) {
                    payRefFees(pending);
                    safeStransfer(to, pending);
                    emit RewardPaid(to, pending);
                }
        }

        if (_amount > 0) {
            //check for deflacionary assets
            _amount = deflacionaryDeposit(pool.lpToken,_amount);

           bool isWhiteListed = isWhiteListed(_pid, to);
           if(isWhiteListed==false && pool.fee > 0){

                uint256  treasuryfee = _amount.mul(pool.fee).mul(fees[3]).div(100000);
                uint256 devfee = _amount.mul(pool.fee).mul(fees[4]).div(100000);

                 if(treasuryfee>0)
                    pool.lpToken.safeTransfer(divPoolAddress, treasuryfee);
                if(devfee>0)
                    pool.lpToken.safeTransfer(devaddr, devfee);

                user.amount = user.amount.add(_amount).sub(treasuryfee).sub(devfee);
            }else{
                user.amount = user.amount.add(_amount);
            }

        }
        user.rewardDebt = user.amount.mul(pool.accslimePerShare).div(1e12);

        emit DepositFor(msg.sender,to, _pid, _amount);
    }

    function deposit(uint256 _pid, uint256 _amount,address referrer) public nonReentrant validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 pending = 0;

        updatePool(_pid);
         if (_amount>0 && rewardReferral != address(0) && referrer != address(0)) {
            SlimeFriends(rewardReferral).setSlimeFriend (msg.sender, referrer);
        }

        if (user.amount > 0) {
              pending = user.amount.mul(pool.accslimePerShare).div(1e12).sub(user.rewardDebt);

               if(pending > 0) {
                    payRefFees(pending);
                    safeStransfer(msg.sender, pending);
                    emit RewardPaid(msg.sender, pending);
                }
        }

        if (_amount > 0) {
            //check for deflacionary assets
            _amount = deflacionaryDeposit(pool.lpToken,_amount);

           bool isWhiteListed = isWhiteListed(_pid, msg.sender);
           if(isWhiteListed==false && pool.fee > 0){

                uint256  treasuryfee = _amount.mul(pool.fee).mul(fees[3]).div(100000);
                uint256 devfee = _amount.mul(pool.fee).mul(fees[4]).div(100000);

                 if(treasuryfee>0)
                    pool.lpToken.safeTransfer(divPoolAddress, treasuryfee);
                if(devfee>0)
                    pool.lpToken.safeTransfer(devaddr, devfee);

                user.amount = user.amount.add(_amount).sub(treasuryfee).sub(devfee);
            }else{
                user.amount = user.amount.add(_amount);
            }

        }
        user.rewardDebt = user.amount.mul(pool.accslimePerShare).div(1e12);

        emit Deposit(msg.sender, _pid, _amount);
    }


    /**
     *  send deposit and check the final amount deposited by a user and if deflation occurs update amount
     *
     */
    function deflacionaryDeposit(IBEP20 token ,uint256 _amount)  internal returns(uint256)
    {

        uint256 balanceBeforeDeposit = token.balanceOf(address(this));
        token.safeTransferFrom(address(msg.sender), address(this), _amount);
        uint256 balanceAfterDeposit = token.balanceOf(address(this));
        _amount = balanceAfterDeposit.sub(balanceBeforeDeposit);

        return _amount;
    }

    /**
     *  Pay harvest and check the final amount harvested by a user and if deflation occurs update amount * used by massHarvestStake
     *
     */
    function deflacionaryHarvest(IBEP20 token ,address to, uint256 _amount)  internal returns(uint256)
    {

        uint256 balanceBeforeHarvest = token.balanceOf(to);
         safeStransfer(to, _amount);
        uint256 balanceAfterHarvest = token.balanceOf(to);
        _amount = balanceAfterHarvest.sub(balanceBeforeHarvest);

        return _amount;
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant validatePoolByPid(_pid) {


        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accslimePerShare).div(1e12).sub(user.rewardDebt);


        if(pending > 0) {
            safeStransfer(msg.sender, pending);
            emit RewardPaid(msg.sender, pending);
        }

        if(_amount > 0)
          {
              user.amount = user.amount.sub(_amount);
              pool.lpToken.safeTransfer(address(msg.sender), _amount);
          }

        user.rewardDebt = user.amount.mul(pool.accslimePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function payRefFees( uint256 pending ) internal
    {
        uint256 toReferral = pending.mul(fees[0]).div(1000);

        address referrer = address(0);
        if (rewardReferral != address(0)) {
            referrer = SlimeFriends(rewardReferral).getSlimeFriend (msg.sender);

        }

        if (referrer != address(0)) { // send commission to referrer
            st.mint(referrer, toReferral);
            emit ReferralPaid(msg.sender, referrer,toReferral);
        }
    }


    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid,amount);

    }

    function changeSlimiesPerBlock(uint256 _slimesPerBlock) external onlyOwner {

        emit UpdateSlimiesPerBlock(slimesPerBlock,_slimesPerBlock);
        slimesPerBlock = _slimesPerBlock;
    }

    function safeStransfer(address _to, uint256 _amount) internal {
        uint256 sbal = st.balanceOf(address(this));
        if (_amount > sbal) {
            st.transfer(_to, sbal);
        } else {
            st.transfer(_to, _amount);
        }
    }


    function updateFees(uint256 _feeID, uint256 _amount) external onlyOwner{

       require(_amount <= MAX_FEE_ALLOWED);
       fees[_feeID] = _amount;

        emit UpdateFees( _feeID, _amount);
    }


    function updateAddresses(address _divPoolAddress,address _devaddr)  external onlyOwner  {

        emit UpdateDivPoolAddress(divPoolAddress,_divPoolAddress);
        divPoolAddress = _divPoolAddress;


        emit UpdateDevAddress(devaddr,_devaddr);
        devaddr = _devaddr;
    }

    function updateTrustedAddress(address _address,bool state) external onlyOwner
    {
        trustedAddress[_address] = state;
        emit UpdateTrustedAddress(_address,state);
    }

     function updateEnableWhitelistFee( bool state) external onlyOwner
    {
        enableWhitelistFee = state;
    }

     function updateWhitelistChefAddress( address _chefAddress) external onlyOwner
    {
        buggyOldChef = _chefAddress;
    }
    //set what will be the stake pool
    function setStakePoolId(uint256 _id)  external onlyOwner  {

        emit UpdateStakePool(stakepoolId,_id);
        stakepoolId = _id;
    }


    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }
}