/*
 * Copyright (c) 2010 C-DAC
 * All rights reserved.
 *
 */

/*
 * @author Trilok I, Sowjanya P
 * triloki@cdac.in, sowjanyap@cdac.in
 *
 */

module TreeP {
  uses {
    interface Boot;
    interface SplitControl as RadioControl;
    interface AMPacket;
    interface AMSend as BeaconSend;
    interface Receive as BeaconReceive;

    interface Timer<TMilli> as BeaconTimer;
    interface Timer<TMilli> as BeaconWaitTimer;
    interface Timer<TMilli> as ConnReqListenTimer;	// Parent
    interface Timer<TMilli> as ConnRepWaitTimer;	// Child
    interface Timer<TMilli> as NeighbourUpdateTimer;	
    interface Timer<TMilli> as NeighbourUpdateStopTimer;	

    interface LocalTime<TMilli> as LocalTime;

    interface Init as SchedulerInit;
    interface TDMASchedule;

    //interface Init as DataManagerInit;

    interface Random;
    interface ParameterInit<uint16_t> as SeedInit;
    interface Leds;
  }

  provides command error_t chooseParent();
}

implementation {

  #define DEFAULT_SEED_VALUE TOS_NODE_ID

  message_t sendBuf;					// Message Buffer used for Beacon/ConnRequest/ConnReply transmissions

  // Beacon Messages
  dozer_beacon_t local;      	 			// Beacon Msg to transmit as Parent

  dozer_parent_t nbrTable[NBR_TABLE_SIZE];		// Neighbours information
  uint8_t index[MAX_POTENTIAL_PARENTS];  

  uint32_t beacon_interval;				// Beacon Transmission Interval as Parent 
  uint8_t gPIndex = 0xFF;				// Parent Node's index in the Neighbour Table
  uint16_t gParent_id = 0xFF;				// Node's Parent ID
  uint16_t listen_id = 0xFF;					// Parent's Node ID whose Beacon we are expecting
  uint16_t child_id;					// Node from which the previous Conn Request is from	

  bool radioOn = FALSE, sendBusy = FALSE;		// Radio is ON and Sending (when both are TRUE)
  bool ParentOn = FALSE, ChildOn = FALSE;		// Radio is ON and Sending (when both are TRUE)
  bool radioBusy = FALSE;
  bool TreeConnected = FALSE;				// Connected to the Tree Network (Initially only the Root Node is connected)
  bool NbrUpdatePending = FALSE;			// TRUE indicates Neighbour Updation undergo
  bool ConnRequestPending = FALSE;			/* Used to indicate a Pending Connection Request 
								which requires the Radio to be 'ON'.*/
  task void send_beacon();
  void startTimer();
  void start_radio();
  void stop_radio();

  void report_problem() { return; }			// Use LEDs to report various status issues.
  void report_sent() { call Leds.led1Toggle(); }
  void report_received() { call Leds.led2Toggle(); }

  event void Boot.booted() {
    uint8_t i;	

    // Initial Values of Nodes Beacon Msg		
    beacon_interval = DEFAULT_BEACON_INTERVAL; 
    local.seed = DEFAULT_SEED_VALUE;
    local.hopcount = INVALID_VALUE;
    local.children = 0;
		
    //call DataManagerInit.init();  
    call SchedulerInit.init();  
    // Initalize the ChildNodes Table of Scheduler & Tree Manager 	
    call TDMASchedule.clearTableEntry(INVALID_VALUE, 0);

    for (i=0; i<NBR_TABLE_SIZE; i++) {
      nbrTable[i].flag          =  INVALID_VALUE;
      nbrTable[i].missed        =  0;
      nbrTable[i].parent_id     =  INVALID_VALUE;
      nbrTable[i].timestamp     =  0;
      nbrTable[i].retries       =  0;
      memset(&nbrTable[i].beacon, 0, sizeof(dozer_beacon_t));
      nbrTable[i].beacon.hopcount = INVALID_VALUE;
    }

    start_radio();      
		
    // If the Node is a Sink/Root Node of the Network, start sending Beacon Msgs
    if (TOS_NODE_ID == ROOT_MOTE_ID) {
      local.hopcount = 0;
      TreeConnected  = TRUE;
      ParentOn = TRUE;	
      post send_beacon();
    } else { 
      call NeighbourUpdateStopTimer.startOneShot(NBR_LISTEN_PERIOD);	
    }	
  }

  // Function to start a Timer to send the Next Beacon Msg
  void startTimer() {
    // Function to start a Timer to send the Next Beacon Msg
    if (TreeConnected) {
      atomic { 
        call SeedInit.init(local.seed);             
        local.seed = call Random.rand16() & 0x1ff; 
      }
      call BeaconTimer.startOneShot(beacon_interval+local.seed);
    }
    else {
      call ConnRepWaitTimer.startOneShot(ACTIVATION_WAIT_PERIOD);
    } 
  } 

  // Function to start Radio
  void start_radio() {   
    if (radioOn) { return; }
    if (call RadioControl.start() != SUCCESS) {
      report_problem();
    }	
  }

  // Function to stop Radio
  void stop_radio() {   
    if (!radioOn || sendBusy || ParentOn || ChildOn || !TreeConnected) { return; }
    if (call RadioControl.stop() != SUCCESS) {
      report_problem();
    }
  }

  // Radio start and stop split phase events
  event void RadioControl.startDone(error_t error) {
    radioOn = TRUE;
    call Leds.led0Off();
  }

  event void RadioControl.stopDone(error_t error) {
    radioOn = FALSE;
    call Leds.led0On();
  }

  event void TDMASchedule.radioWakeup(uint8_t type, uint16_t node_id) {
    uint8_t rounds = 1, i = gPIndex;

    switch (type)
    {
      case BEACON_LISTEN:
	ChildOn = TRUE;
        start_radio();
        listen_id = node_id;

        if (listen_id != gParent_id) {
          rounds = (PARENTS_UPDATE_INTERVAL/DEFAULT_BEACON_INTERVAL);

    	  for (i = 0; i < NBR_TABLE_SIZE; i++) {            
            if (nbrTable[i].parent_id == listen_id) { break; }
	  }
        } 

	if (i == NBR_TABLE_SIZE) {
	   ChildOn = FALSE;
	   stop_radio();
	   // Clear this entry in the Potential Parents Table
	   // or add this entry in the Neighbor table ????
	   ;
	}
        call BeaconWaitTimer.startOneShot(2*rounds*(nbrTable[i].missed+1)*CLOCK_DRIFT_COMPENSATION + 1);
        break;

      case TSLOT_LISTEN:
	ParentOn = TRUE;
        start_radio();
        break;

      case TSLOT_LISTEN_STOP:
	ParentOn = FALSE;
        stop_radio();
        break;

      case TSLOT_DATA_SEND:
	ChildOn = TRUE;
        start_radio();
        break;

      case TSLOT_DATA_SEND_STOP:
	ChildOn = FALSE;
        stop_radio();
        break;

      default:
        break;
    }
  }

  event void BeaconTimer.fired() {
    if (!radioOn) 
      start_radio();
    
    if (TreeConnected) {
       ParentOn = TRUE;	
       post send_beacon();
    }
  }
  
  /* Guard Time = twice Clock Drift Compensation over the Period
     Clock Drift Compensation = 100ppm
     Clock Drift Compensation = (100 * (Clock_Frequency = 7.32MHz)/Million)Hz			
  			      = 100 * 7.32 = 732 Hz
     Clock Drift Compensation(Millisec) = (732/7.32)* 10^-6* 10^3 
				        = 0.1 MilliSec per Sec
     A Delay of "1ms" is provided for the Radio to Stabilize after starting
  */

  event void ConnRepWaitTimer.fired() {
    if (!TreeConnected) {
      call chooseParent();
    }
  }

  event void NeighbourUpdateTimer.fired() {
    call TDMASchedule.stopTimers();
    start_radio();
    NbrUpdatePending = TRUE;
    call NeighbourUpdateStopTimer.startOneShot(NBR_LISTEN_PERIOD);	
  }

  event void NeighbourUpdateStopTimer.fired() {
    if (!TreeConnected) {
      call chooseParent();
    } else {
      stop_radio(); 
      NbrUpdatePending = FALSE;
      call TDMASchedule.startTimers();
      call NeighbourUpdateTimer.startOneShot(NBR_UPDATION_PERIOD);	
    }
  }

  event void BeaconWaitTimer.fired() {
    // Increment Missed Beacons Count
    ChildOn = FALSE;
    stop_radio();
    call TDMASchedule.setParentTimeStamp(listen_id, NULL, call LocalTime.get());
  }

  event void ConnReqListenTimer.fired() {
    ParentOn = FALSE; 
    stop_radio();
  }
/*
    if (!ConnRequestPending) {
      stop_radio();
    } else {
      ConnRequestPending = FALSE;
      call TDMASchedule.clearTableEntry(child_id, FALSE);	
      local.children--;
    }
  }
*/  
  task void send_beacon() {
    dozer_msg_t *dmsg; 

    if (radioOn && !sendBusy) {
      // Don't need to check for null because we've already checked length
      // above
      dmsg = (dozer_msg_t *)call BeaconSend.getPayload(&sendBuf, sizeof(dozer_msg_t)); 	
      dmsg->type = DOZER_BEACON;   
      //if (TOS_NODE_ID)	
      //  local.children = nbrTable[gPIndex].beacon.seed; 	
      memcpy(&dmsg->dozer_data[0], &local, sizeof(local));
      if (call BeaconSend.send(AM_BROADCAST_ADDR, &sendBuf, sizeof(dozer_msg_t)) == SUCCESS) {
	sendBusy = TRUE;
      } 
    } else { post send_beacon(); }

    if (!sendBusy)
      report_problem();
  }

  task void sendRequest() {
    dozer_msg_t *dmsg; 
    //dozer_conn_req_t connreq;				// Request for connection in Tree
    if (radioOn && !sendBusy) {
      dmsg = (dozer_msg_t *)call BeaconSend.getPayload(&sendBuf, sizeof(dozer_msg_t)); 	
      dmsg->type = DOZER_CONNREQ;
      if (call BeaconSend.send(gParent_id, &sendBuf, sizeof(dozer_msg_t)) == SUCCESS) {
        sendBusy = TRUE;
      }	
    } 
  }
 
  task void sendReply() {
    dozer_msg_t *dmsg; 
    dozer_conn_rep_t connRep;				// Reply for connection in Tree

    connRep.tdma_slot = call TDMASchedule.allocChildTimeSlot(child_id, &local);
    if (connRep.tdma_slot == INVALID_VALUE) { return; }
    if (radioOn && !sendBusy) {
      dmsg = (dozer_msg_t *)call BeaconSend.getPayload(&sendBuf, sizeof(dozer_msg_t)); 	
      dmsg->type  = DOZER_CONNREP;
      memcpy(&dmsg->dozer_data[0], &connRep, sizeof connRep);
      if (call BeaconSend.send(child_id, &sendBuf, sizeof(dozer_msg_t)) == SUCCESS) {
        sendBusy = TRUE;
      }  	
    } else { post sendReply(); }
  }

  task void sendReplyAck() {
    dozer_msg_t *dmsg; 

    if (radioOn && !sendBusy) {
      dmsg = (dozer_msg_t *)call BeaconSend.getPayload(&sendBuf, sizeof(dozer_msg_t)); 	
      dmsg->type  = DOZER_CONNACK;
      if (call BeaconSend.send(gParent_id, &sendBuf, sizeof(dozer_msg_t)) == SUCCESS) {
        sendBusy = TRUE;
      }	  
    }
  }
 

  command error_t chooseParent() {
    dozer_parent_t *adr; // *temp=nbrTable;
    uint8_t         i;

    TreeConnected = FALSE;
    call TDMASchedule.getPPB(&adr);

    if (adr->flag != INVALID_VALUE) {
      for (i=0; i<NBR_TABLE_SIZE; i++) {
        if (adr->parent_id == nbrTable[i].parent_id) {
          gParent_id = nbrTable[i].parent_id;
          gPIndex = i; 
          break;
        }
      }
    }
    else {
      call BeaconTimer.stop();	
      call TDMASchedule.clearTableEntry(INVALID_VALUE, INVALID_VALUE);
      start_radio();	
      call NeighbourUpdateStopTimer.startOneShot(NBR_LISTEN_PERIOD);	
    }
    return SUCCESS;
  }

  void replaceEntry(uint16_t src, dozer_beacon_t beacon, uint32_t time_stamp) 
  {
    uint8_t  i, Index = 0;
	
    atomic {	
      for (i = 0; i < NBR_TABLE_SIZE; i++) {            
	 if ((nbrTable[i].parent_id != gParent_id)
	     && (nbrTable[Index].beacon.hopcount >= nbrTable[i].beacon.hopcount)
	     && (nbrTable[Index].retries >= nbrTable[i].retries)) {
	   Index = i;
         } 
      }	
    }
    nbrTable[Index].flag = 1;
    nbrTable[Index].parent_id = src;
    nbrTable[Index].missed = 0;			
    nbrTable[Index].timestamp = time_stamp;
    memcpy(&(nbrTable[Index].beacon), &beacon, sizeof beacon);
  }

  void updateNgbrs(uint16_t src, dozer_beacon_t beacon, uint32_t time_stamp) 	 
  {     
    uint8_t i, j, tableUpdated = 0;		
    //dozer_parent_t ppb;

    // check wheather source is already existed in table
    for (i = 0; i < NBR_TABLE_SIZE; i++) {            
      // if exits and entry is valid then update that particular entry  
      if (nbrTable[i].parent_id == src) {
	tableUpdated = 1;		              
	if (nbrTable[i].flag == 1) {  
 	  nbrTable[i].timestamp = time_stamp;			
 	  nbrTable[i].missed = 0;			
	  memcpy(&nbrTable[i].beacon, &beacon, sizeof beacon);
	  break;	
        } 
	else {
          // if exits and entry is invalid then update that particular entry                   
	  nbrTable[i].retries = 0;
	  nbrTable[i].flag = 1;
 	  nbrTable[i].missed = 0;			
	  memcpy(&nbrTable[i].beacon, &beacon, sizeof beacon);
	  nbrTable[i].timestamp = time_stamp;
	  memcpy(&nbrTable[i].beacon, &beacon, sizeof beacon);
          break;
        } 
      }	
    }
              
    if (!tableUpdated) {
      // Sort entries which are INVALID  ....
      quick_sort(nbrTable, INV, sizeof(dozer_parent_t));
      // if it is not existed, update value in first INVALID_VALUE entry
      if (nbrTable[0].flag == INVALID_VALUE) {	                    
	nbrTable[0].flag = 1;
        nbrTable[0].parent_id = src;
	nbrTable[0].missed = 0;			
        nbrTable[0].timestamp = time_stamp;			
	nbrTable[0].retries = 0;
	tableUpdated = 1;
	memcpy(&nbrTable[0].beacon, &beacon, sizeof beacon);
      }     
    } 

    // if no entry is free (i.e table is full)  then replace entry in table
    if (!tableUpdated) {						 
      replaceEntry(src, beacon, time_stamp);
    }

    // Sort entries based on hopcount  ....
    quick_sort(nbrTable, HC, sizeof(dozer_parent_t));

    // store indices of ppb's
    for (j=0, i=NBR_TABLE_SIZE; i!=0; i--){
       if ((nbrTable[i-1].flag != INVALID_VALUE) &&  (j < MAX_POTENTIAL_PARENTS)) {
   	 index[j++] = i-1;
       }
    } 

    call TDMASchedule.setPPB(index, nbrTable, j); 
  }

  event message_t* BeaconReceive.receive(message_t* msg, void* payload, uint8_t len) 
  {
    uint8_t x=1;		
    dozer_msg_t *dmsg = (dozer_msg_t*)payload;
    dozer_conn_rep_t *connRep;
    //dozer_conn_req_t *connReq;	
    dozer_beacon_t *bmsg, beacon;	
    uint16_t src = call AMPacket.source(msg);

    //report_received();
    	 
    // Give the Beacon Reception Timestamp to Scheduler Module	
    switch (dmsg->type) {
	case DOZER_BEACON:       
	  report_received();

	  if (TOS_NODE_ID == ROOT_MOTE_ID) { return msg; }

	  bmsg = (dozer_beacon_t*)&(dmsg->dozer_data[0]);
          memcpy(&beacon, bmsg, sizeof beacon);

	  if (!TreeConnected && (src == gParent_id)) { 
    	    post sendRequest(); 
          } 

	  if (TreeConnected && !NbrUpdatePending) {
	    if (src == listen_id) {
	      call BeaconWaitTimer.stop();
	      call TDMASchedule.setParentTimeStamp(src, bmsg, call LocalTime.get());
	      ChildOn = FALSE;	
	      stop_radio();
	    }	
	  } else {	
	    if ((bmsg->children >= MAX_CHILDREN) && (src != gParent_id)) { return msg; }	
	    updateNgbrs(src, beacon, call LocalTime.get());
	  }	
	  break;

	case DOZER_CONNREQ:   
	  call ConnReqListenTimer.stop();
	  /*if (local.children >= MAX_CHILDREN) {		///// Case is not supposed to occur
	    ParentOn = FALSE;
	    stop_radio();	
	    break;
	  }*/
	  child_id = src; 
	  post sendReply();
	  break;

	case DOZER_CONNACK:  
	  call ConnReqListenTimer.stop();
	  stop_radio();
	  ConnRequestPending = FALSE;
	  break;

	case DOZER_CONNREP:   
	  call ConnRepWaitTimer.stop();	
	  connRep = (dozer_conn_rep_t*)&(dmsg->dozer_data[0]);
	  call TDMASchedule.setParentTDMASlot(connRep->tdma_slot);
	  TreeConnected = TRUE; 	
	  local.hopcount = nbrTable[gPIndex].beacon.hopcount + 1;
	  call TDMASchedule.startTimers(); 	
          call NeighbourUpdateTimer.startOneShot(NBR_UPDATION_PERIOD);	
	  stop_radio();	
	  call BeaconTimer.startOneShotAt(nbrTable[gPIndex].timestamp, CHILD_CONNECTION_PERIOD+(MAX_CHILDREN*TDMA_SLOT_LEN)+0x1ff);
	  //post sendReplyAck();
	  break; 
    }
    return msg;	
  }

  event void BeaconSend.sendDone(message_t* msg, error_t error) {
    dozer_msg_t *dmsg = call BeaconSend.getPayload(&sendBuf, sizeof(dozer_msg_t));

    report_sent();
    sendBusy = FALSE;

//    if (error == SUCCESS) {
      switch (dmsg->type) {        
	case DOZER_BEACON:       
      	  startTimer();
    	  call TDMASchedule.setBeaconTimeStamp(call LocalTime.get());
          if (local.children < MAX_CHILDREN) {		// Need to add a condition for BS NODE
	    call ConnReqListenTimer.startOneShot(ACTIVATION_WAIT_PERIOD);
	  }/* else {	
	    ParentOn = FALSE; 	
	    stop_radio();
          }*/
	  break;

        case DOZER_CONNREQ: 
      	  startTimer();
	  break;

	case DOZER_CONNREP:
	  ParentOn = FALSE; 	
	  stop_radio();
	  //ConnRequestPending = TRUE;
	  //call ConnReqListenTimer.startOneShot(CHILD_CONNECTION_PERIOD);
	  break;

        case DOZER_CONNACK:
	  stop_radio();
	  break;
	
	default:
	  break;  
      } 
	  
//    } else { report_problem(); }

  }

}
