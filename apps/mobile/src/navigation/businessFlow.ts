import { CommonActions } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { BusinessStackParamList } from './BusinessStack';
import { navigateTab } from './navigationRef';

type BusinessFlowScreen = 'CreateJob' | 'OfferJob';

// ViewBaristaProfile and OfferJob are mounted in several tabs, but CreateJob
// (and OfferJob, for Chats) live only in the Business tab.
export const navigateBusinessFlow = <S extends BusinessFlowScreen>(
  navigation: NativeStackNavigationProp<BusinessStackParamList>,
  screen: S,
  params: BusinessStackParamList[S]
): void => {
  const routeNames: readonly string[] = navigation.getState().routeNames;
  if (routeNames.includes(screen)) {
    navigation.dispatch(CommonActions.navigate({ name: screen, params }));
    return;
  }
  navigateTab('Business', { screen, params: params ?? undefined });
};
