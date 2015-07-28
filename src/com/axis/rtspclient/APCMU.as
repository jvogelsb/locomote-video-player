package com.axis.rtspclient {
  import com.axis.rtspclient.ByteArrayUtils;
  import com.axis.rtspclient.RTP;
  import com.axis.Logger;

  import flash.events.Event;
  import flash.events.EventDispatcher;
  import flash.external.ExternalInterface;
  import flash.utils.ByteArray;

  /* Assembler of PCMU frames */
  public class APCMU extends EventDispatcher {

    public function APCMU() {}

    public function onRTPPacket(pkt:RTP):void {
      var ts:Number = pkt.getTimestampMS()
      var data:ByteArray = pkt.getPayload();

      var smallPktSize:uint = 160
      var smallPktTime:uint = 20 //smallPktSize * (1/8000)
      var pcmuData:ByteArray = new ByteArray();
      for (var i:int = 0; i < pkt.bodyLength / smallPktSize; i++) {
        pcmuData.writeBytes(data, (i * smallPktSize) + data.position, smallPktSize);
        dispatchEvent(new PCMUFrame(pcmuData, ts + (i * smallPktTime)));
        pcmuData.clear()
      }
    }
  }
}
