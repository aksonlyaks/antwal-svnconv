# TOSSIM python script for the simultation of the HoppingTest application 
# using HoppingEngineM components to perform routing.
# It must be created a file with the topology with the form: node1  node2  gain
# Also it has to be provided the meyer_heavy file from TOSSIM that is
# a list of noise values taken from the meyer library ar Berkeley
# that allows to generate a statistical model to calculate the SNR
# * @author Ricardo Simon Carbajo <carbajor@cs.tcd.ie>
# * @date   Sept 18 2007 
# * Computer Science
# * Trinity College Dublin

import sys
from random import *
#from TOSSIM import *
from tinyos.tossim import *

t = Tossim([])
r = t.radio();


##########
#TOPOLOGY
##########

f = open("Topologies/topo12perfect.txt", "r")

lines = f.readlines()
for line in lines:
  s = line.split()
  if (len(s) > 0):
    if (s[0] == "gain"):
      #if (((int(s[1])) <= 30) & ((int(s[2])) <= 30)):
        print " ", s[1], " ", s[2], " ", s[3];
        r.add(int(s[1]), int(s[2]), float(s[3]));
	numNodes=int(s[1]);
print "numnodes ",int(s[1]);
######################
#NOISE TRACE & BOOTING
######################

noise = open("Noise/meyer-heavy-short.txt", "r")
#noise = open("Noise/meyer-heavy.txt", "r")
lines = noise.readlines()
for line in lines:
  str = line.strip()
  if (str != ""):
    val = int(str)
    for i in range(0, numNodes+1):
      t.getNode(i).addNoiseTraceReading(val)

for i in range(0, numNodes+1):
  print "Creating noise model for ",i;
  t.getNode(i).createNoiseModel();

for i in range(0, numNodes+1):
  #bootTime=randint(1000,20000) * 1;
  bootTime=i * 2351217 + 23542399;
  t.getNode(i).bootAtTime(bootTime);
  print "Boot Time for Node ",i, ": ",bootTime; 

#########
#CHANNELS
#########



bla = open("Simulations/Energy.txt", "w");
t.addChannel("ENERGY_HANDLER", bla); 

t.addChannel("TESTLEDS", sys.stdout);

##########
#EXEC LOOP
##########

t.runNextEvent();
time=t.time();
            # 1000000000000 = 100 seconds
while (time + 100000000000 > t.time()):
  t.runNextEvent();

